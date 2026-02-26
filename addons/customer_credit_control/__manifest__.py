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
