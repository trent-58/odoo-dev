#!/usr/bin/env bash
set -euo pipefail

# ---- folders ----
mkdir -p addons odoo-data db-data

# ---- odoo.conf ----
cat > odoo.conf <<'CONF'
[options]
admin_passwd = admin
db_host = db
db_port = 5432
db_user = odoo
db_password = odoo

; Keep defaults + our addon path
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons

; optional, but nice for dev
log_level = info
workers = 0
limit_time_cpu = 120
limit_time_real = 240
CONF

# ---- docker-compose.yml ----
cat > docker-compose.yml <<'YML'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: odoo
    volumes:
      - ./db-data:/var/lib/postgresql/data
    ports:
      - "5433:5432"

  odoo:
    image: odoo:17
    depends_on:
      - db
    ports:
      - "8069:8069"
    volumes:
      - ./odoo.conf:/etc/odoo/odoo.conf:ro
      - ./odoo-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    # Fixes common fresh-volume crash: missing /var/lib/odoo/addons/17.0
    command: bash -lc "mkdir -p /var/lib/odoo/addons/17.0 /var/lib/odoo/.local/share/Odoo/addons/17.0 && odoo -c /etc/odoo/odoo.conf"
YML

# ============================================================
# ADDON 1: customer_credit_control
# ============================================================
mkdir -p addons/customer_credit_control/{models,views,security}

cat > addons/customer_credit_control/__init__.py <<'PY'
from . import models
PY

cat > addons/customer_credit_control/models/__init__.py <<'PY'
from . import customer_credit_limit
from . import sale_order
PY

cat > addons/customer_credit_control/__manifest__.py <<'PY'
{
    "name": "Customer Credit Control",
    "version": "17.0.1.0.0",
    "category": "Sales",
    "summary": "Customer credit limits integrated with Sales and Accounting",
    "license": "LGPL-3",
    "depends": ["sale_management", "account"],
    "data": [
        "security/security.xml",
        "security/ir.model.access.csv",
        "views/customer_credit_limit_views.xml",
        "views/sale_order_views.xml",
    ],
    "installable": True,
    "application": False,
}
PY

cat > addons/customer_credit_control/models/customer_credit_limit.py <<'PY'
from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class CustomerCreditLimit(models.Model):
    _name = "customer.credit.limit"
    _description = "Customer Credit Limit"
    _order = "id desc"

    partner_id = fields.Many2one("res.partner", required=True, ondelete="cascade", index=True)
    credit_limit = fields.Monetary(required=True)
    currency_id = fields.Many2one(
        "res.currency",
        required=True,
        default=lambda self: self.env.company.currency_id.id,
    )
    active = fields.Boolean(default=True)
    note = fields.Text()

    total_due = fields.Monetary(compute="_compute_total_due", store=True, currency_field="currency_id")
    remaining_credit = fields.Monetary(compute="_compute_remaining_credit", store=True, currency_field="currency_id")

    @api.depends("partner_id", "active")
    def _compute_total_due(self):
        Move = self.env["account.move"]
        for rec in self:
            if not rec.partner_id:
                rec.total_due = 0.0
                continue

            commercial = rec.partner_id.commercial_partner_id
            moves = Move.search([
                ("move_type", "=", "out_invoice"),
                ("state", "=", "posted"),
                ("amount_residual", ">", 0),
                ("partner_id", "child_of", commercial.id),
            ])
            # NOTE: This sums amount_residual as-is. If you need multi-currency conversion, add conversion here.
            rec.total_due = sum(moves.mapped("amount_residual"))

    @api.depends("credit_limit", "total_due")
    def _compute_remaining_credit(self):
        for rec in self:
            rec.remaining_credit = (rec.credit_limit or 0.0) - (rec.total_due or 0.0)

    @api.constrains("partner_id", "active")
    def _check_one_active_per_partner(self):
        for rec in self:
            if not rec.active or not rec.partner_id:
                continue
            commercial = rec.partner_id.commercial_partner_id
            dup = self.search_count([
                ("id", "!=", rec.id),
                ("active", "=", True),
                ("partner_id", "child_of", commercial.id),
            ])
            if dup:
                raise ValidationError(_("Only one ACTIVE credit limit is allowed per customer (commercial entity)."))
PY

cat > addons/customer_credit_control/models/sale_order.py <<'PY'
from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class SaleOrder(models.Model):
    _inherit = "sale.order"

    credit_limit_id = fields.Many2one(
        "customer.credit.limit",
        compute="_compute_credit_limit_id",
        store=False,
    )
    credit_total_due = fields.Monetary(
        compute="_compute_credit_info",
        store=False,
        currency_field="currency_id",
    )
    credit_remaining = fields.Monetary(
        compute="_compute_credit_info",
        store=False,
        currency_field="currency_id",
    )

    @api.depends("partner_id")
    def _compute_credit_limit_id(self):
        Limit = self.env["customer.credit.limit"].sudo()
        for order in self:
            order.credit_limit_id = False
            if not order.partner_id:
                continue
            commercial = order.partner_id.commercial_partner_id
            limit = Limit.search([
                ("active", "=", True),
                ("partner_id", "child_of", commercial.id),
            ], limit=1)
            order.credit_limit_id = limit

    @api.depends("credit_limit_id", "amount_total", "partner_id")
    def _compute_credit_info(self):
        for order in self:
            if not order.credit_limit_id:
                order.credit_total_due = 0.0
                order.credit_remaining = 0.0
                continue
            # read computed values from limit (stored compute)
            order.credit_total_due = order.credit_limit_id.total_due
            order.credit_remaining = order.credit_limit_id.remaining_credit

    def action_confirm(self):
        for order in self:
            limit = order.credit_limit_id
            if limit:
                # IMPORTANT: Ensure currencies match (simple version assumes same currency)
                if limit.currency_id != order.currency_id:
                    raise ValidationError(_(
                        "Currency mismatch: Credit Limit is in %s but the Sale Order is in %s."
                    ) % (limit.currency_id.name, order.currency_id.name))

                projected = (limit.total_due or 0.0) + (order.amount_total or 0.0)
                if projected > (limit.credit_limit or 0.0):
                    raise ValidationError(_(
                        "Credit limit exceeded!\n\n"
                        "Limit: %(limit).2f %(cur)s\n"
                        "Current due: %(due).2f %(cur)s\n"
                        "Order total: %(order).2f %(cur)s\n"
                        "Projected: %(proj).2f %(cur)s"
                    ) % {
                        "limit": limit.credit_limit,
                        "due": limit.total_due,
                        "order": order.amount_total,
                        "proj": projected,
                        "cur": limit.currency_id.name,
                    })

        return super().action_confirm()
PY

cat > addons/customer_credit_control/security/security.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <!-- Credit Limit Manager: implied by Accounting Manager -->
    <record id="group_credit_limit_manager" model="res.groups">
        <field name="name">Credit Limit Manager</field>
        <field name="implied_ids" eval="[(4, ref('account.group_account_manager'))]"/>
    </record>
</odoo>
XML

cat > addons/customer_credit_control/security/ir.model.access.csv <<'CSV'
id,name,model_id:id,group_id:id,perm_read,perm_write,perm_create,perm_unlink
access_customer_credit_limit_manager,customer.credit.limit manager,model_customer_credit_limit,customer_credit_control.group_credit_limit_manager,1,1,1,1
access_customer_credit_limit_sales_read,customer.credit.limit sales read,model_customer_credit_limit,sales_team.group_sale_salesman,1,0,0,0
CSV

cat > addons/customer_credit_control/views/customer_credit_limit_views.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="view_customer_credit_limit_tree" model="ir.ui.view">
        <field name="name">customer.credit.limit.tree</field>
        <field name="model">customer.credit.limit</field>
        <field name="arch" type="xml">
            <tree>
                <field name="partner_id"/>
                <field name="credit_limit"/>
                <field name="currency_id"/>
                <field name="total_due"/>
                <field name="remaining_credit"/>
                <field name="active"/>
            </tree>
        </field>
    </record>

    <record id="view_customer_credit_limit_form" model="ir.ui.view">
        <field name="name">customer.credit.limit.form</field>
        <field name="model">customer.credit.limit</field>
        <field name="arch" type="xml">
            <form>
                <sheet>
                    <group>
                        <field name="partner_id"/>
                        <field name="credit_limit"/>
                        <field name="currency_id"/>
                        <field name="active"/>
                    </group>
                    <group>
                        <field name="total_due" readonly="1"/>
                        <field name="remaining_credit" readonly="1"/>
                    </group>
                    <group>
                        <field name="note"/>
                    </group>
                </sheet>
            </form>
        </field>
    </record>

    <record id="action_customer_credit_limit" model="ir.actions.act_window">
        <field name="name">Customer Credit Limits</field>
        <field name="res_model">customer.credit.limit</field>
        <field name="view_mode">tree,form</field>
    </record>

    <menuitem id="menu_customer_credit_root" name="Credit Control" parent="account.menu_finance" sequence="90"
              groups="customer_credit_control.group_credit_limit_manager"/>
    <menuitem id="menu_customer_credit_limits" name="Customer Credit Limits"
              parent="menu_customer_credit_root" action="action_customer_credit_limit" sequence="10"
              groups="customer_credit_control.group_credit_limit_manager"/>
</odoo>
XML

cat > addons/customer_credit_control/views/sale_order_views.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <!-- Inject credit info into Sale Order -->
    <record id="view_sale_order_form_credit_info" model="ir.ui.view">
        <field name="name">sale.order.form.credit.info</field>
        <field name="model">sale.order</field>
        <field name="inherit_id" ref="sale.view_order_form"/>
        <field name="arch" type="xml">
            <!-- Make sure these fields exist in the view (Odoo requires that) -->
            <xpath expr="//sheet" position="inside">
                <field name="credit_limit_id" invisible="1"/>
                <field name="credit_total_due" invisible="1"/>
                <field name="credit_remaining" invisible="1"/>
            </xpath>

            <!-- Show info near the top -->
            <xpath expr="//sheet//group" position="before">
                <group string="Credit Control" invisible="credit_limit_id == False">
                    <field name="credit_total_due" readonly="1"/>
                    <field name="credit_remaining" readonly="1"/>
                    <div class="alert alert-warning" role="alert" invisible="credit_remaining &gt;= 0">
                        Remaining credit is negative. This customer is over the limit.
                    </div>
                </group>
            </xpath>
        </field>
    </record>
</odoo>
XML

# ============================================================
# ADDON 2: mini_sales_approval
# ============================================================
mkdir -p addons/mini_sales_approval/{models,views,security,data}

cat > addons/mini_sales_approval/__init__.py <<'PY'
from . import models
PY

cat > addons/mini_sales_approval/models/__init__.py <<'PY'
from . import sale_approval_request
from . import sale_order
PY

cat > addons/mini_sales_approval/__manifest__.py <<'PY'
{
    "name": "Mini Sales Approval",
    "version": "17.0.1.0.0",
    "category": "Sales",
    "summary": "Approval workflow for high value sale orders",
    "license": "LGPL-3",
    "depends": ["sale_management", "sales_team"],
    "data": [
        "data/sequence.xml",
        "security/security.xml",
        "security/ir.model.access.csv",
        "views/sale_approval_request_views.xml",
        "views/sale_order_views.xml",
    ],
    "installable": True,
    "application": False,
}
PY

cat > addons/mini_sales_approval/data/sequence.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="seq_sale_approval_request" model="ir.sequence">
        <field name="name">Sale Approval Request</field>
        <field name="code">sale.approval.request</field>
        <field name="prefix">SAR/</field>
        <field name="padding">5</field>
    </record>
</odoo>
XML

cat > addons/mini_sales_approval/security/security.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="group_sale_approval_user" model="res.groups">
        <field name="name">Sales Approval User</field>
        <field name="implied_ids" eval="[(4, ref('sales_team.group_sale_salesman'))]"/>
    </record>

    <record id="group_sale_approval_manager" model="res.groups">
        <field name="name">Sales Approval Manager</field>
        <field name="implied_ids" eval="[(4, ref('sales_team.group_sale_manager'))]"/>
    </record>
</odoo>
XML

cat > addons/mini_sales_approval/security/ir.model.access.csv <<'CSV'
id,name,model_id:id,group_id:id,perm_read,perm_write,perm_create,perm_unlink
access_sale_approval_user,sale.approval.request user,model_sale_approval_request,mini_sales_approval.group_sale_approval_user,1,1,1,0
access_sale_approval_manager,sale.approval.request manager,model_sale_approval_request,mini_sales_approval.group_sale_approval_manager,1,1,1,1
CSV

cat > addons/mini_sales_approval/models/sale_approval_request.py <<'PY'
from odoo import api, fields, models, _
from odoo.exceptions import UserError


class SaleApprovalRequest(models.Model):
    _name = "sale.approval.request"
    _description = "Sale Approval Request"
    _order = "id desc"

    name = fields.Char(default=lambda self: _("New"), readonly=True, copy=False)
    sale_order_id = fields.Many2one("sale.order", required=True, ondelete="cascade")
    requested_by = fields.Many2one("res.users", default=lambda self: self.env.user, readonly=True)
    approved_by = fields.Many2one("res.users", readonly=True)
    state = fields.Selection([
        ("draft", "Draft"),
        ("submitted", "Submitted"),
        ("approved", "Approved"),
        ("rejected", "Rejected"),
    ], default="draft", required=True)
    reject_reason = fields.Text()

    currency_id = fields.Many2one(related="sale_order_id.currency_id", store=True, readonly=True)
    total_amount = fields.Monetary(compute="_compute_total", store=True, currency_field="currency_id")

    @api.depends("sale_order_id.amount_total")
    def _compute_total(self):
        for rec in self:
            rec.total_amount = rec.sale_order_id.amount_total or 0.0

    @api.model_create_multi
    def create(self, vals_list):
        seq = self.env["ir.sequence"]
        for vals in vals_list:
            if vals.get("name", _("New")) == _("New"):
                vals["name"] = seq.next_by_code("sale.approval.request") or _("New")
        return super().create(vals_list)

    def action_submit(self):
        for rec in self:
            if rec.state != "draft":
                continue
            rec.state = "submitted"
        return True

    def action_approve(self):
        # only Sales Approval Manager should approve (security handles it)
        for rec in self:
            if rec.state not in ("submitted",):
                continue
            rec.state = "approved"
            rec.approved_by = self.env.user

            # Auto confirm the sale order if still not confirmed
            order = rec.sale_order_id
            if order.state in ("draft", "sent"):
                order.with_context(skip_approval_check=True).action_confirm()
        return True

    def action_reject(self):
        for rec in self:
            if rec.state not in ("submitted",):
                continue
            if not rec.reject_reason:
                raise UserError(_("Please write a reject reason before rejecting."))
            rec.state = "rejected"
            rec.approved_by = self.env.user
        return True
PY

cat > addons/mini_sales_approval/models/sale_order.py <<'PY'
from odoo import api, fields, models, _
from odoo.exceptions import UserError


class SaleOrder(models.Model):
    _inherit = "sale.order"

    approval_request_count = fields.Integer(compute="_compute_approval_count", store=False)

    def _compute_approval_count(self):
        Approval = self.env["sale.approval.request"].sudo()
        for order in self:
            order.approval_request_count = Approval.search_count([("sale_order_id", "=", order.id)])

    def action_view_approvals(self):
        self.ensure_one()
        return {
            "type": "ir.actions.act_window",
            "name": _("Approvals"),
            "res_model": "sale.approval.request",
            "view_mode": "tree,form",
            "domain": [("sale_order_id", "=", self.id)],
            "context": {"default_sale_order_id": self.id},
        }

    def action_confirm(self):
        # Allow auto-confirm from approval approve action
        if self.env.context.get("skip_approval_check"):
            return super().action_confirm()

        Approval = self.env["sale.approval.request"].sudo()

        for order in self:
            if order.amount_total > 10000:
                # Do we have an approved approval?
                approved = Approval.search([
                    ("sale_order_id", "=", order.id),
                    ("state", "=", "approved"),
                ], limit=1)
                if approved:
                    continue

                # Otherwise create (or reuse) a submitted request and stop confirm
                existing = Approval.search([
                    ("sale_order_id", "=", order.id),
                    ("state", "in", ("draft", "submitted", "rejected")),
                ], limit=1)

                if not existing:
                    existing = Approval.create({
                        "sale_order_id": order.id,
                        "state": "submitted",
                    })
                elif existing.state == "draft":
                    existing.action_submit()

                raise UserError(_(
                    "This Sale Order requires approval because the total is above 10,000.\n"
                    "An Approval Request has been created/submitted.\n\n"
                    "Open the Approval smart button to proceed."
                ))

        return super().action_confirm()
PY

cat > addons/mini_sales_approval/views/sale_approval_request_views.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="view_sale_approval_request_tree" model="ir.ui.view">
        <field name="name">sale.approval.request.tree</field>
        <field name="model">sale.approval.request</field>
        <field name="arch" type="xml">
            <tree>
                <field name="name"/>
                <field name="sale_order_id"/>
                <field name="requested_by"/>
                <field name="approved_by"/>
                <field name="state"/>
                <field name="total_amount"/>
            </tree>
        </field>
    </record>

    <record id="view_sale_approval_request_form" model="ir.ui.view">
        <field name="name">sale.approval.request.form</field>
        <field name="model">sale.approval.request</field>
        <field name="arch" type="xml">
            <form>
                <header>
                    <!-- IMPORTANT: quote selection values -->
                    <button name="action_submit" type="object" string="Submit" class="btn-primary"
                            invisible="state != 'draft'"/>
                    <button name="action_approve" type="object" string="Approve" class="btn-primary"
                            groups="mini_sales_approval.group_sale_approval_manager"
                            invisible="state != 'submitted'"/>
                    <button name="action_reject" type="object" string="Reject" class="btn-secondary"
                            groups="mini_sales_approval.group_sale_approval_manager"
                            invisible="state != 'submitted'"/>
                    <field name="state" widget="statusbar" statusbar_visible="draft,submitted,approved,rejected"/>
                </header>

                <sheet>
                    <group>
                        <field name="name" readonly="1"/>
                        <field name="sale_order_id"/>
                        <field name="requested_by" readonly="1"/>
                        <field name="approved_by" readonly="1"/>
                        <field name="total_amount" readonly="1"/>
                    </group>

                    <group string="Reject Reason" invisible="state != 'rejected'">
                        <field name="reject_reason"/>
                    </group>

                    <group string="Reason (required before rejecting)" invisible="state != 'submitted'">
                        <field name="reject_reason"/>
                    </group>
                </sheet>
            </form>
        </field>
    </record>
</odoo>
XML

cat > addons/mini_sales_approval/views/sale_order_views.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="view_sale_order_form_approval_button" model="ir.ui.view">
        <field name="name">sale.order.form.approval.button</field>
        <field name="model">sale.order</field>
        <field name="inherit_id" ref="sale.view_order_form"/>
        <field name="arch" type="xml">
            <xpath expr="//div[@name='button_box']" position="inside">
                <button type="object" name="action_view_approvals" class="oe_stat_button" icon="fa-check-square-o">
                    <field name="approval_request_count" widget="statinfo" string="Approval"/>
                </button>
            </xpath>
        </field>
    </record>
</odoo>
XML

# ---- run.sh ----
cat > run.sh <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
docker compose up -d
echo "Odoo is starting... open: http://127.0.0.1:8069"
echo "Postgres: localhost:5432 user=odoo pass=odoo"
RUN
chmod +x run.sh

# ---- upgrade.sh (run after DB exists) ----
cat > upgrade.sh <<'UP'
#!/usr/bin/env bash
set -euo pipefail
DB="${1:-jasmin-database}"
docker exec -it $(docker compose ps -q odoo) bash -lc "odoo -c /etc/odoo/odoo.conf -d '$DB' -u customer_credit_control -u mini_sales_approval --stop-after-init"
docker compose restart odoo
echo "Upgraded modules in DB '$DB' and restarted Odoo."
UP
chmod +x upgrade.sh

echo "✅ bootstrap.sh finished."
echo "Next: ./run.sh"
