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

                # Otherwise create (or reuse) a submitted request and stop confirm.
                # Rejected requests are historical and should not block resubmission.
                existing = Approval.search([
                    ("sale_order_id", "=", order.id),
                    ("state", "in", ("draft", "submitted")),
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
