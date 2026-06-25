{% macro set_query_tag(extra = {}) -%}
    {% do run_query('use warehouse ' ~ var('warehouse_recommendation_lookup', 'CP_DBT_XSMALL_WH_V2')) %}
    {% set relation = api.Relation.create(
        database='OPS_CUR',
        schema='WH_RECOMMENDATIONS',
        identifier='DIM_WAREHOUSE_RECOMMENDATION'
    ) %}

    {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% set default_warehouse = var('warehouse_recommendation_default', 'CP_DBT_LARGE_WH_V2') %}

    {% set rec_query %}
        select
            override_warehouse_name,
            recommended_warehouse_size
        from {{ relation }}
        where source_uri = '{{ model.name }}'
            and airflow = '{{ airflow_run }}'
        limit 1
    {% endset %}

    {% set warehouseName = default_warehouse %}
    {% if execute %}
        {% set results = run_query(rec_query) %}
        {% if results and results.rows | length > 0 %}
            {% set row = results.rows[0] %}
            {% if row[0] %}
                {% set warehouseName = row[0] %}
            {% elif row[1] %}
                {% set warehouseName = 'cp_dbt_' ~ row[1].replace('-', '') ~ '_wh_v2' %}
            {% endif %}
        {% endif %}
    {% endif %}

    {% set merged_extra = extra.copy() %}
    {% do merged_extra.update({
        'invocation_id': invocation_id,
        'model': model.name,
        'is_airflow_run': airflow_run
    }) %}

    {% set result = adapter.dispatch('set_query_tag', 'dbt_query_tags')(extra=merged_extra) %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}

{%- endmacro %}
