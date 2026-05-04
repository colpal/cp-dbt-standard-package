{#
    Override snowflake__create_table_built_in_sql to inject Iceberg type-safety layer.

    Problem: Snowflake Iceberg v2 tables do not support certain data types natively:
        - TIMESTAMP_LTZ/NTZ/TZ with precision != 6
        - TIMESTAMP_TZ (not supported at all — must convert to TIMESTAMP_LTZ)
        - VARIANT, ARRAY, OBJECT (must be stringified to VARCHAR)
        - VARCHAR(L)/STRING(L) with length constraints (must be unconstrained)

    Solution: For BUILT_IN catalog (Iceberg) tables, we:
        1. Create a temporary view from the original compiled_code
        2. Introspect the view to discover actual column types
        3. Build a safe SELECT with CASTs for incompatible types
        4. Pass the safe SQL to the native adapter sub-macro

    Architecture: We override snowflake__create_table_built_in_sql (not
    snowflake__create_table_as). The native adapter's snowflake__create_table_as
    handles all catalog routing and build_catalog_relation() calls. It then
    disp10es to this sub-macro for BUILT_IN Iceberg tables. This avoids
    DbtCatalogIntegrationNotFoundError when custom catalogs from catalogs.yml
    are not yet registered (e.g., during dbt ls / parsing).

    The native dbt-snowflake 1.11+ adapter also handles:
    - dbt_snowflake_get_tmp_relation_type (forces 'table' for BUILT_IN)
    - Non-Iceberg table routing (INFO_SCHEMA, ICEBERG_REST, temporary)
    So we no longer need to override those.
#}

{% macro snowflake__create_table_built_in_sql(
    relation, compiled_code
) -%}

{#-- Apply type-safe casts for Iceberg-incompatible types --#}
{%- set safe_compiled_code =
    iceberg_type_safe_wrap(compiled_code) -%}

{#-- Delegate to native BUILT_IN DDL generation with safe SQL --#}
{{ dbt.snowflake__create_table_built_in_sql(
    relation, safe_compiled_code
) }}

{%- endmacro %}


{#
    Wraps compiled_code with Iceberg-safe type casts.

    Approach:
        1. Create a temporary view from compiled_code (metadata-only, no compute)
        2. Introspect the view to discover actual column data types
        3. If no problematic types found, return compiled_code unchanged
        4. Otherwise, build a SELECT with CASTs wrapping the original compiled_code
            as a subquery (no view dependency in the final CTAS)
        5. Drop the introspection view
#}
{% macro iceberg_type_safe_wrap(compiled_code) %}
    {%- set temp_view = make_temp_relation(this).incorporate(type='view') -%}

    {% call statement('create_type_introspection_view') %}
        {{ create_view_as(temp_view, compiled_code) }}
    {% endcall %}

    {%- set columns = adapter.get_columns_in_relation(temp_view) -%}

    {#-- Check if any columns need type-safe casting --#}
    {%- set needs_casting = [] -%}
    {%- for col in columns -%}
        {%- set col_type_upper = col.dtype | upper -%}
        {%- set stripped_dtype = col.dtype | replace(' ', '') | upper -%}
        {%- set is_unspecified_number = (
            'NUMBER' in col_type_upper
            or 'DECIMAL' in col_type_upper
            or 'NUMERIC' in col_type_upper
        ) and (
            '(' not in col.dtype
            or '38,0' in stripped_dtype
        ) -%}
        {%- if 'TIMESTAMP' in col_type_upper
            or col_type_upper in ['VARIANT', 'ARRAY', 'OBJECT']
            or 'VARCHAR' in col_type_upper
            or 'STRING' in col_type_upper
            or is_unspecified_number -%}
            {%- do needs_casting.append(col) -%}
        {%- endif -%}
    {%- endfor -%}

    {#-- Drop the introspection view — no longer needed --#}
    {% call statement('drop_type_introspection_view') %}
        DROP VIEW IF EXISTS {{ temp_view }}
    {% endcall %}

    {%- if needs_casting | length == 0 -%}
        {#-- No problematic types: return original SQL unchanged --#}
        {{ return(compiled_code) }}
    {%- endif -%}

    {#-- Build type-safe projection wrapping original SQL as subquery --#}
    {%- set safe_sql -%}
SELECT
{% for col in columns %}
            {%- set col_type_upper = col.dtype | upper -%}
            {%- set stripped_dtype = col.dtype | replace(' ', '') | upper -%}
{%- set is_unspecified_number = (
    'NUMBER' in col_type_upper
    or 'DECIMAL' in col_type_upper
    or 'NUMERIC' in col_type_upper
) and (
    '(' not in col.dtype
    or '38,0' in stripped_dtype
) -%}
            {%- if 'TIMESTAMP_LTZ' in col_type_upper -%}
                    CAST("{{ col.column }}" AS TIMESTAMP_LTZ(6)) AS "{{ col.column }}"
                {%- elif 'TIMESTAMP_NTZ' in col_type_upper -%}
                    CAST("{{ col.column }}" AS TIMESTAMP_NTZ(6)) AS "{{ col.column }}"
                {%- elif 'TIMESTAMP_TZ' in col_type_upper -%}
                    CAST("{{ col.column }}" AS TIMESTAMP_LTZ(6)) AS "{{ col.column }}"
                {%- elif 'TIMESTAMP' in col_type_upper -%}
                    CAST("{{ col.column }}" AS TIMESTAMP_NTZ(6)) AS "{{ col.column }}"
                {%- elif col_type_upper in ['VARIANT', 'ARRAY', 'OBJECT'] -%}
                    CAST(TO_JSON("{{ col.column }}") AS VARCHAR(134217728)) AS "{{ col.column }}"
                {%- elif 'VARCHAR' in col_type_upper or 'STRING' in col_type_upper -%}
                    CAST("{{ col.column }}" AS VARCHAR(134217728)) AS "{{ col.column }}"
                {%- elif is_unspecified_number -%}
                    CAST("{{ col.column }}" AS NUMBER(38, 0)) AS "{{ col.column }}"
                {%- else -%}
                "{{ col.column }}"
            {%- endif -%}
            {%- if not loop.last -%}, {% endif -%}
        {%- endfor %}
        FROM (
            {{ compiled_code }}
        ) AS __iceberg_type_safe_source
    {%- endset -%}

    {{ return(safe_sql) }}
{% endmacro %}


{#
    Removed: snowflake__alter_relation_comment and snowflake__alter_column_comment
    backports from dbt-snowflake 1.10.0 (fix #1015). These are handled natively
    in dbt-snowflake >= 1.11.0 and are no longer needed.
#}
