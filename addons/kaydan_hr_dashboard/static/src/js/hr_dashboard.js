/** @odoo-module **/

import { Component, useState, onWillStart } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";

const EMPTY = {
    companies: [], company_id: false, kpis: {},
    by_department: [], by_gender: [], by_employee_type: [], by_contract_type: [],
    evolution: [], recruitment: [], recent_arrivals: [], top_leaves: [], top_departures: [],
};

export class KaydanHrDashboard extends Component {
    static template = "kaydan_hr_dashboard.Dashboard";
    static props = ["*"];

    setup() {
        this.orm = useService("orm");
        this.state = useState({ loading: true, companyId: false, data: EMPTY });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.loading = true;
        this.state.data = await this.orm.call(
            "hr.employee", "get_kaydan_dashboard_data", [this.state.companyId || false]
        );
        this.state.loading = false;
    }

    async onCompanyChange(ev) {
        const v = ev.target.value;
        this.state.companyId = v ? parseInt(v, 10) : false;
        await this.load();
    }

    /** Cartes KPI présentes dans les données */
    get cards() {
        const k = this.state.data.kpis || {};
        const defs = [
            ["total", "Effectif total"],
            ["departments", "Départements"],
            ["new_this_month", "Arrivées ce mois"],
            ["present_now", "Présents maintenant"],
            ["leaves_to_approve", "Congés à approuver"],
            ["departures_12m", "Départs (12 mois)"],
        ];
        return defs.filter(([key]) => k[key] !== undefined).map(([key, label]) => ({ label, value: k[key] }));
    }
}

registry.category("actions").add("kaydan_hr_dashboard", KaydanHrDashboard);
