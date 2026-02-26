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
