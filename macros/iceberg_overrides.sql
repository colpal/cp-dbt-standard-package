{#
===============================================================================
MACRO FILE: iceberg_overrides.sql
PURPOSE:    Globally intercepts dbt's native Snowflake materialization macros to 
            enforce Apache Iceberg type safety and bypass strict contract errors.
            Non-Iceberg models fall through to native dbt behavior.
===============================================================================
#}

{# ============================================================================
   SECTION 1: INCREMENTAL STAGING OVERRIDE
   Forces temp tables instead of views so the type-safe wrapper catches
   arrays and casts them before the MERGE.
   ============================================================================ #}

{% macro dbt_snowflake_get_tmp_relation_type(strategy, unique_key, language) %}
    {{ log("[iceberg_overrides] >>> dbt_snowflake_get_tmp_relation_type OVERRIDE REACHED", info=true) }}
    {{ return("table") }}
{% endmacro %}


{# ============================================================================
   SECTION 3: MATERIALIZATION OVERRIDES (Safe Temp Table Routing)
   ============================================================================ #}

{% macro snowflake__create_table_as(temporary, relation, compiled_code, language='sql') -%}
    {{ log("[iceberg_overrides] >>> snowflake__create_table_as OVERRIDE REACHED for: " ~ relation, info=true) }}
    {%- if language == 'sql' -%}
        {% set safe_sql = iceberg_type_safe_wrap(compiled_code) %}
        {% set pre_relation = relation.incorporate(path={"identifier": relation.identifier ~ "__dbt_pre"}) %}
        {% if execute %}
            {% set create_temp_sql = "CREATE OR REPLACE TEMPORARY TABLE " ~ pre_relation ~ " AS \n" ~ safe_sql %}
            {% do run_query(create_temp_sql) %}
        {% endif %}
        {% set final_sql = "SELECT * FROM " ~ pre_relation %}
        {{ return(dbt.snowflake__create_table_as(temporary, relation, final_sql, language)) }}
    {%- else -%}
        {{ return(dbt.snowflake__create_table_as(temporary, relation, compiled_code, language)) }}
    {%- endif -%}
{%- endmacro %}

{% macro snowflake__create_view_as(relation, sql) -%}
    {% set safe_sql = iceberg_type_safe_wrap(sql) %}
    {{ return(dbt.snowflake__create_view_as(relation, safe_sql)) }}
{%- endmacro %}

{% macro snowflake__get_create_table_as_sql(temporary, relation, sql) -%}
    {{ log("[iceberg_overrides] >>> snowflake__get_create_table_as_sql OVERRIDE REACHED for: " ~ relation, info=true) }}
    {% set safe_sql = iceberg_type_safe_wrap(sql) %}
    {% set pre_relation = relation.incorporate(path={"identifier": relation.identifier ~ "__dbt_pre"}) %}
    {% if execute %}
        {% set create_temp_sql = "CREATE OR REPLACE TEMPORARY TABLE " ~ pre_relation ~ " AS \n" ~ safe_sql %}
        {% do run_query(create_temp_sql) %}
    {% endif %}
    {% set final_sql = "SELECT * FROM " ~ pre_relation %}
    {{ return(dbt.default__get_create_table_as_sql(temporary, relation, final_sql)) }}
{%- endmacro %}


{# ============================================================================
   SECTION 5: THE WRAPPER ENGINE (Dynamic Introspection & Casting)
   ============================================================================ #}

{% macro iceberg_type_safe_wrap(compiled_code) %}
    {%- set temp_view = make_temp_relation(this).incorporate(type='view') -%}

    {% call statement('create_type_introspection_view') %}
        {{ config.get('sql_header', '') }}
        CREATE OR REPLACE VIEW {{ temp_view }} AS ( {{ compiled_code }} )
    {% endcall %}

    {%- set describe_sql = "DESCRIBE VIEW " ~ temp_view -%}
    {%- set results = run_query(describe_sql) -%}

    {%- set needs_casting = [] -%}
    {%- set final_columns = [] -%}

    {%- if execute -%}
        {%- for row in results.rows -%}
            {%- set col_name = row['name'] -%}
            {%- set col_type = row['type'] | string | upper -%}
            {%- set stripped_type = col_type | replace(" ", "") -%}
            
            {%- set is_unspecified_number = ('NUMBER' in col_type or 'DECIMAL' in col_type or 'NUMERIC' in col_type) and ('(' not in col_type or '38,0' in stripped_type) -%}
            
            {%- if 'TIMESTAMP' in col_type or 'VARIANT' in col_type or 'ARRAY' in col_type or 'OBJECT' in col_type or 'VARCHAR' in col_type or 'STRING' in col_type or is_unspecified_number -%}
                {%- do needs_casting.append(col_name) -%}
            {%- endif -%}
            {%- do final_columns.append({'name': col_name, 'type': col_type}) -%}
        {%- endfor -%}
    {%- endif -%}

    {% call statement('drop_type_introspection_view') %}
        DROP VIEW IF EXISTS {{ temp_view }}
    {% endcall %}

    {%- if needs_casting | length == 0 -%}
        {{ return(compiled_code) }}
    {%- endif -%}

    {%- set safe_sql -%}
        SELECT
        {% for col in final_columns %}
            {%- set col_name = col.name -%}
            {%- set col_type = col.type -%}
            {%- set stripped_type = col_type | replace(" ", "") -%}
            {%- set is_unspecified_number = ('NUMBER' in col_type or 'DECIMAL' in col_type or 'NUMERIC' in col_type) and ('(' not in col_type or '38,0' in stripped_type) -%}

            {%- if 'TIMESTAMP_LTZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_LTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP_NTZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_NTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP_TZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_LTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_NTZ(6)) AS "{{ col_name }}"
            {%- elif 'VARIANT' in col_type or 'ARRAY' in col_type or 'OBJECT' in col_type -%}
                CAST(TO_JSON("{{ col_name }}") AS VARCHAR(134217728)) AS "{{ col_name }}"
            {%- elif 'VARCHAR' in col_type or 'STRING' in col_type -%}
                CAST("{{ col_name }}" AS VARCHAR(134217728)) AS "{{ col_name }}"
            {%- elif is_unspecified_number -%}
                CAST("{{ col_name }}" AS NUMBER(38, 0)) AS "{{ col_name }}"
            {%- else -%}
                "{{ col_name }}"
            {%- endif -%}
            {%- if not loop.last -%}, {% endif -%}
        {%- endfor %}
        FROM (
            {{ compiled_code }}
        ) AS __iceberg_type_safe_source
    {%- endset -%}

    {{ return(safe_sql) }}
{% endmacro %}
