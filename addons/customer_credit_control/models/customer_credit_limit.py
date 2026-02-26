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

    total_due = fields.Monetary(compute="_compute_total_due", store=False, currency_field="currency_id")
    remaining_credit = fields.Monetary(compute="_compute_remaining_credit", store=False, currency_field="currency_id")

    @api.depends("partner_id")
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
