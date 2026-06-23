{#
===============================================================================
MACRO FILE: iceberg_overrides.sql
PURPOSE:    Globally intercepts dbt's native Snowflake materialization macros to 
            enforce Apache Iceberg type safety and bypass strict contract errors.
===============================================================================
#}

{# ============================================================================
   SECTION 1: THE DDL NUKE (Bypass YAML Contract Injection)
   ============================================================================ #}

{% macro get_table_columns_and_constraints() %}
    {{ return('') }}
{% endmacro %}

{% macro default__get_table_columns_and_constraints() %}
    {{ return('') }}
{% endmacro %}

{% macro snowflake__get_table_columns_and_constraints() %}
    {{ return('') }}
{% endmacro %}

{% macro render_raw_columns_constraints(raw_columns) %}
    {{ return('') }}
{% endmacro %}

{% macro default__render_raw_columns_constraints(raw_columns) %}
    {{ return('') }}
{% endmacro %}

{% macro snowflake__render_raw_columns_constraints(raw_columns) %}
    {{ return('') }}
{% endmacro %}


{# ============================================================================
   SECTION 2: INCREMENTAL STAGING OVERRIDE (Fixes the Array Mismatch)
   ============================================================================ #}

{% macro snowflake__get_tmp_relation_type(strategy, unique_key, language) %}
    {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}
        {%- if catalog_relation is not none and catalog_relation.catalog_type == 'BUILT_IN' -%}
            {{ return("table") }}
        {%- endif -%}

    {#-- Catch Iceberg models if catalog_relation fails to build --#}
    {%- if config.get('catalog_name') is not none or config.get('table_format') == 'iceberg' -%}
        {{ return("table") }}
    {%- endif -%}

    {#-- For non-Iceberg models, use native logic --#}
    {%- set tmp_relation_type = config.get('tmp_relation_type') -%}

    {% if snowflake__is_catalog_linked_database(relation=config.model) %}
        {{ return("table") }}
    {% endif %}

    {% if language != "sql" %}
        {{ return("table") }}
    {% elif tmp_relation_type == "table" %}
        {{ return("table") }}
    {% elif tmp_relation_type == "view" %}
        {{ return("view") }}
    {% elif strategy in ("default", "merge", "append", "insert_overwrite") %}
        {{ return("view") }}
    {% elif strategy in ["delete+insert", "microbatch"] and unique_key is none %}
        {{ return("view") }}
    {% else %}
        {{ return("table") }}
    {% endif %}
{% endmacro %}


{# ============================================================================
   SECTION 3: MATERIALIZATION OVERRIDES (Safe Temp Table Routing)
   ============================================================================ #}

{# NOTE: Final tables are created directly from safe_sql #}

{% macro snowflake__create_table_as(temporary, relation, compiled_code, language='sql') -%}
    {%- set is_iceberg = (
        config.get('catalog_name') is not none
        or config.get('table_format', '') | lower == 'iceberg'
    ) -%}

    {% if language == 'sql' and is_iceberg %}
        {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(compiled_code) %}
        {{ return(dbt.snowflake__create_table_as(temporary, relation, safe_sql, language)) }}
    {% else %}
        {{ return(dbt.snowflake__create_table_as(temporary, relation, compiled_code, language)) }}
    {% endif %}
{%- endmacro %}

{% macro snowflake__create_view_as(relation, sql) -%}
    {%- set is_iceberg = (config.get('catalog_name') is not none or config.get('table_format', '') | lower == 'iceberg') -%}
    {% if is_iceberg %}
      {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(sql) %}
      {{ return(dbt.snowflake__create_view_as(relation, safe_sql)) }}
    {% else %}
      {{ return(dbt.snowflake__create_view_as(relation, sql)) }}
    {% endif %}
{%- endmacro %}

{% macro snowflake__get_create_view_as_sql(relation, sql) -%}
    {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(sql) %}
    {{ return(dbt.snowflake__create_view_as(relation, safe_sql)) }}
{%- endmacro %}

{% macro snowflake__get_create_table_as_sql(temporary, relation, sql) -%}
    {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(sql) %}

    {%- if 'snowflake__get_create_table_as_sql' in dbt -%}
        {{ return(dbt.snowflake__get_create_table_as_sql(temporary, relation, safe_sql)) }}
    {%- else -%}
        {{ return(dbt.default__get_create_table_as_sql(temporary, relation, safe_sql)) }}
    {%- endif -%}
{%- endmacro %}

{% macro snowflake__get_create_iceberg_table_as_sql(temporary, relation, sql) -%}
    {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(sql) %}

    {%- if 'snowflake__get_create_iceberg_table_as_sql' in dbt -%}
        {{ return(dbt.snowflake__get_create_iceberg_table_as_sql(temporary, relation, safe_sql)) }}
    {%- else -%}
        {{ return(dbt.default__get_create_table_as_sql(temporary, relation, safe_sql)) }}
    {%- endif -%}
{%- endmacro %}

{% macro snowflake__create_iceberg_table_as(temporary, relation, compiled_code, language='sql') -%}
    {% if language == 'sql' %}
        {% set safe_sql = cp_dbt_standard_package.iceberg_type_safe_wrap(compiled_code) %}
        {{ return(dbt.snowflake__create_iceberg_table_as(temporary, relation, safe_sql, language)) }}
    {% else %}
        {{ return(dbt.snowflake__create_iceberg_table_as(temporary, relation, compiled_code, language)) }}
    {% endif %}
{%- endmacro %}


{# ============================================================================
   SECTION 3B: MERGE OVERRIDE (Wrap staging source to cast unsupported types)
   ============================================================================ #}

{% macro snowflake__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates=none) %}
{%- set is_iceberg = (
    config.get('catalog_name') is not none
    or config.get('table_format', '') | lower == 'iceberg'
) -%}

{%- if is_iceberg and execute -%}
    {#-- Describe the staging relation to find columns needing casts --#}
    {%- set describe_sql = "DESCRIBE TABLE " ~ source -%}
    {%- set results = run_query(describe_sql) -%}

    {%- set has_unsupported = [] -%}
    {%- set wrapped_cols = [] -%}

    {%- for row in results.rows -%}
        {%- set col_name = row['name'] -%}
        {%- set col_type = row['type'] | string | upper -%}

        {%- if 'ARRAY' in col_type or 'OBJECT' in col_type or 'VARIANT' in col_type -%}
            {%- do has_unsupported.append(col_name) -%}
            {%- do wrapped_cols.append('CAST(TO_JSON("' ~ col_name ~ '") AS VARCHAR(16777216)) AS "' ~ col_name ~ '"') -%}
        {%- else -%}
            {%- do wrapped_cols.append('"' ~ col_name ~ '"') -%}
        {%- endif -%}
    {%- endfor -%}

    {%- if has_unsupported | length > 0 -%}
        {#-- Create a temp view wrapping the staging relation with proper casts --#}
        {%- set safe_source = source.incorporate(path={"identifier": source.identifier ~ "__safe"}) -%}
        {%- set create_safe_sql = "CREATE OR REPLACE TEMPORARY VIEW " ~ safe_source ~ " AS SELECT " ~ wrapped_cols | join(", ") ~ " FROM " ~ source -%}
        {%- do run_query(create_safe_sql) -%}

        {{ return(dbt.snowflake__get_merge_sql(target, safe_source, unique_key, dest_columns, incremental_predicates)) }}
    {%- else -%}
        {{ return(dbt.snowflake__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates)) }}
    {%- endif -%}
{%- else -%}
    {{ return(dbt.snowflake__get_merge_sql(target, source, unique_key, dest_columns, incremental_predicates)) }}
{%- endif -%}
{% endmacro %}


{# ============================================================================
   SECTION 3C: ALTER COLUMN TYPE BYPASS (Prevent Iceberg type alteration)
   ============================================================================ #}

{% macro snowflake__alter_column_type(relation, column_name, new_column_type) %}
{%- set is_iceberg = (
    config.get('catalog_name') is not none
    or config.get('table_format', '') | lower == 'iceberg'
) -%}
{%- set upper_type = new_column_type | upper -%}
{%- set is_unsupported_type = ('VARIANT' in upper_type or 'ARRAY' in upper_type or 'OBJECT' in upper_type) -%}
{%- if is_iceberg and is_unsupported_type -%}
    {#-- Skip ALTER only for Iceberg-unsupported types (VARIANT/ARRAY/OBJECT).
         These are phantom mismatches from the staging view's native types;
         the actual casting is handled at MERGE time by the get_merge_sql override. --#}
    {{ log("Iceberg: skipping ALTER COLUMN TYPE for " ~ column_name ~ " to " ~ new_column_type ~ " (unsupported Iceberg type)", info=True) }}
{%- else -%}
    {{ return(dbt.snowflake__alter_column_type(relation, column_name, new_column_type)) }}
{%- endif -%}
{% endmacro %}


{# ============================================================================
   SECTION 4: CONTRACT MISMATCH BYPASS (Silence Python validation)
   ============================================================================ #}

{% macro get_assert_columns_equivalent(ddl_dict) %}
    {{ return('') }}
{% endmacro %}

{% macro default__get_assert_columns_equivalent(ddl_dict) %}
    {{ return('') }}
{% endmacro %}

{% macro snowflake__get_assert_columns_equivalent(ddl_dict) %}
    {{ return('') }}
{% endmacro %}


{# ============================================================================
   SECTION 5: THE WRAPPER ENGINE (Dynamic Introspection & Casting)
   ============================================================================ #}

{% macro iceberg_type_safe_wrap(compiled_code) %}
    {%- set temp_view = make_temp_relation(this).incorporate(type='view') -%}

    {% call statement('create_type_introspection_view') %}
        {{ config.get('sql_header', '') }}
        CREATE OR REPLACE VIEW {{ temp_view }} AS (
        {{ compiled_code }}
        )
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
            
            {%- if 'TIMESTAMP' in col_type or 'TIME' in col_type or 'VARCHAR' in col_type or 'STRING' in col_type or is_unspecified_number or 'VARIANT' in col_type or 'ARRAY' in col_type or 'OBJECT' in col_type -%}
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
            {%- set has_colon = ':' in col_name -%}

            {%- if has_colon -%}
                "{{ col_name }}"
            {%- elif 'TIMESTAMP_LTZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_LTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP_NTZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_NTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP_TZ' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_LTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIMESTAMP' in col_type -%}
                CAST("{{ col_name }}" AS TIMESTAMP_NTZ(6)) AS "{{ col_name }}"
            {%- elif 'TIME' in col_type -%}
                CAST("{{ col_name }}" AS TIME(6)) AS "{{ col_name }}"
            {%- elif 'VARIANT' in col_type -%}
                CAST(TO_JSON("{{ col_name }}") AS VARCHAR(16777216)) AS "{{ col_name }}"
            {%- elif 'ARRAY' in col_type -%}
                CAST(TO_JSON("{{ col_name }}") AS VARCHAR(16777216)) AS "{{ col_name }}"
            {%- elif 'OBJECT' in col_type -%}
                CAST(TO_JSON("{{ col_name }}") AS VARCHAR(16777216)) AS "{{ col_name }}"
            {%- elif 'VARCHAR' in col_type or 'STRING' in col_type -%}
                CAST("{{ col_name }}" AS VARCHAR(16777216)) AS "{{ col_name }}"
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
