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

    def _get_active_credit_limit(self):
        self.ensure_one()
        if not self.partner_id:
            return self.env["customer.credit.limit"]
        return self.env["customer.credit.limit"].sudo().search([
            ("active", "=", True),
            ("partner_id", "child_of", self.partner_id.commercial_partner_id.id),
        ], limit=1, order="id desc")

    @api.depends("partner_id")
    def _compute_credit_limit_id(self):
        for order in self:
            order.credit_limit_id = order._get_active_credit_limit()

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
            # Re-fetch at confirm-time to avoid relying on a computed cache value.
            limit = order._get_active_credit_limit()
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
