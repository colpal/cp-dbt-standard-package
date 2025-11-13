{% macro set_query_tag(model=None, invocation_id=None, airflow_run=None, extra={}) -%}
    
    {#--------------------------------------------------------------#}
    {# 0. Parameter Defaults & Context Detection                    #}
    {#--------------------------------------------------------------#}

    {# If caller passed a model, use it. Otherwise fall back
       to dbt's "model" var when available. #}
    {% if model is none and (model is defined) %}
        {% set model = model %}
    {% endif %}

    {# If still no model → non-model context (tests, snapshots, seeds, docs) #}
    {% if model is none %}
        {% do return(None) %}
    {% endif %}

    {# invocation_id fallback #}
    {% if invocation_id is none %}
        {% set invocation_id = invocation_id %}
    {% endif %}

    {# airflow_run fallback #}
    {% if airflow_run is none %}
        {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% endif %}

    {# Standardized names #}
    {% set node_name = model.name %}
    {% set node_resource_type = model.resource_type %}

    {% set node_schema = model.schema if model.schema is not none else target.schema %}
    {% set node_database = model.database if model.database is not none else target.database %}

    {#--------------------------------------------------------------#}
    {# 1. Warehouse Recommendation (Models Only)                    #}
    {#--------------------------------------------------------------#}
    {% if node_resource_type == "model" %}

        {% set relation = api.Relation.create(
            database='OPS_CUR',
            schema='WH_RECOMMENDATIONS',
            identifier='DIM_WAREHOUSE_RECOMMENDATION'
        ) %}

        {% set where_statement = "source_uri = '" ~ node_name ~ "' and airflow = '" ~ airflow_run ~ "'" %}

        {% set warehouse = dbt_utils.get_column_values(
            relation,
            'RECOMMENDED_WAREHOUSE_NAME',
            default=['CP_DBT_LARGE_WH_V2'],
            where=where_statement
        ) %}
        {% set warehouse_name = warehouse[0] if warehouse else 'CP_DBT_LARGE_WH_V2' %}

    {% else %}
        {% set warehouse_name = None %}
    {% endif %}

    {#--------------------------------------------------------------#}
    {# 2. Build Query Tag Metadata                                  #}
    {#--------------------------------------------------------------#}

    {% set metadata = extra.copy() %}
    {% do metadata.update({
        'invocation_id': invocation_id,
        'resource_type': node_resource_type,
        'name': node_name,
        'schema': node_schema,
        'database': node_database,
        'is_airflow_run': airflow_run,
        'warehouse_used': warehouse_name
    }) %}

    {#--------------------------------------------------------------#}
    {# 3. Adapter-dispatched Tagging Logic                          #}
    {#--------------------------------------------------------------#}

    {% set result = adapter.dispatch(
        'set_query_tag',
        'dbt_snowflake_query_tags'
    )(extra=metadata) %}

    {#--------------------------------------------------------------#}
    {# 4. Warehouse Switching (Models Only)                         #}
    {#--------------------------------------------------------------#}

    {% if node_resource_type == 'model' and warehouse_name is not none %}
        {% do run_query('USE WAREHOUSE "' ~ warehouse_name.upper() ~ '"') %}
    {% endif %}

    {{ return(result) }}

{%- endmacro %}
