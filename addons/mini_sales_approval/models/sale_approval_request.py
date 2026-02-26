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
