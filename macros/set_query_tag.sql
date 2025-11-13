{% macro set_query_tag(model=None, invocation_id=None, airflow_run=None) -%}

    {# -----------------------------------------------------------------
       0. Model detection
       dbt will call this macro for models, snapshots, tests, seeds, docs,
       on-run hooks, defer-state compilation. Only run during model builds.
       ----------------------------------------------------------------- #}
    {% if model is none %}
        {% if model is defined %}
            {% set model = model %}
        {% else %}
            {% do return(None) %}
        {% endif %}
    {% endif %}

    {# If still no model, stop #}
    {% if model is none %}
        {% do return(None) %}
    {% endif %}

    {# -----------------------------------------------------------------
       1. Argument defaults (dbt passes invocation_id automatically)
       ----------------------------------------------------------------- #}
    {% if invocation_id is none %}
        {% set invocation_id = invocation_id %}
    {% endif %}

    {% if airflow_run is none %}
        {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% endif %}

    {% set model_name = model.name %}
    {% set model_schema = model.schema if model.schema is not none else target.schema %}
    {% set model_database = model.database if model.database is not none else target.database %}

    {# -----------------------------------------------------------------
       2. Read warehouse recommendation table
       ----------------------------------------------------------------- #}
    {% set relation = api.Relation.create(
        database='OPS_CUR',
        schema='WH_RECOMMENDATIONS',
        identifier='DIM_WAREHOUSE_RECOMMENDATION'
    ) %}

    {% set where_clause = "source_uri = '" ~ model_name ~ "' and airflow = '" ~ airflow_run ~ "'" %}

    {% set warehouse_list = dbt_utils.get_column_values(
        relation,
        'RECOMMENDED_WAREHOUSE_NAME',
        default=['CP_DBT_LARGE_WH_V2'],
        where=where_clause
    ) %}

    {% set warehouse_name = warehouse_list[0] if warehouse_list else 'CP_DBT_LARGE_WH_V2' %}

    {# -----------------------------------------------------------------
       3. Apply query tag
       ----------------------------------------------------------------- #}
    {% set tag_payload = {
        "invocation_id": invocation_id,
        "model_name": model_name,
        "schema": model_schema,
        "database": model_database,
        "is_airflow_run": airflow_run,
        "warehouse_used": warehouse_name
    } %}

    {% do run_query("alter session set query_tag = '" ~ tojson(tag_payload) ~ "'") %}

    {# -----------------------------------------------------------------
       4. Switch warehouse
       ----------------------------------------------------------------- #}
    {% do run_query('USE WAREHOUSE "' ~ warehouse_name.upper() ~ '"') %}

    {% do return(None) %}
{%- endmacro %}
