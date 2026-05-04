{#
    Override snowflake__create_table_as to inject Iceberg type-safety layer.

    Problem: Snowflake Iceberg v2 tables do not support certain data types natively:
        - TIMESTAMP_LTZ/NTZ/TZ with precision != 6
        - TIMESTAMP_TZ (not supported at all — must convert to TIMESTAMP_LTZ)
        - VARIANT, ARRAY, OBJECT (must be stringified to VARCHAR)
        - VARCHAR(L)/STRING(L) with length constraints (must be unconstrained)

    Solution: For BUILT_IN catalog (Iceberg) tables, we:
        1. Create a temporary view from the original compiled_code
        2. Introspect the view to discover actual column types
        3. Build a safe SELECT with CASTs for incompatible types
        4. Pass the safe SQL to the native adapter sub-macros

    For non-Iceberg tables (INFO_SCHEMA, temporary), we pass through unchanged.
    This override is forward-compatible with dbt-snowflake 1.11.0+ because it
    delegates all DDL generation to the native snowflake__create_table_*_sql macros.
#}

{#
    Override dbt_snowflake_get_tmp_relation_type to force 'table' for BUILT_IN Iceberg
    models. This ensures incremental runs always create a temp TABLE (not a view), which
    routes through create_table_as(True, ...) where our type-safety layer is applied.
    Without this, strategies like merge/append would create a temp view with raw types,
    and the subsequent MERGE/INSERT into the Iceberg target could fail on incompatible types.
#}
{% macro dbt_snowflake_get_tmp_relation_type(strategy, unique_key, language) %}
    {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}
    {%- if catalog_relation.catalog_type == 'BUILT_IN' -%}
        {{ return("table") }}
    {%- endif -%}

    {#-- For non-Iceberg models, use native logic --#}
    {%- set tmp_relation_type = config.get('tmp_relation_type') -%}

    {% if language == "python"
        and tmp_relation_type is not none %}
        {% do exceptions.raise_compiler_error(
            "Python models currently only support "
            "'table' for tmp_relation_type but "
            ~ tmp_relation_type ~ " was specified."
        ) %}
    {% endif %}

    {#-- Python always uses a temporary table --#}
    {% if language != "sql" %}
        {{ return("table") }}
    {% endif %}

    {#-- CLD only supports Iceberg tables --#}
    {% if snowflake__is_catalog_linked_database(
        relation=config.model
    ) %}
        {{ return("table") }}
    {% endif %}

    {% if strategy in ["delete+insert", "microbatch"]
        and tmp_relation_type is not none
        and tmp_relation_type not in ("table", "transient")
        and unique_key is not none %}
        {% do exceptions.raise_compiler_error(
            "In order to maintain consistent results"
            " when `unique_key` is not none, the `"
            ~ strategy ~ "` strategy only supports "
            "`table` or `transient` for "
            "`tmp_relation_type` but "
            ~ tmp_relation_type ~ " was specified."
        ) %}
    {% endif %}

    {% if tmp_relation_type == "table" %}
        {{ return("table") }}
    {% elif tmp_relation_type == "view" %}
        {{ return("view") }}
    {% elif tmp_relation_type == "transient" %}
        {{ return("transient") }}
    {% elif strategy in ("default", "merge", "append", "insert_overwrite") %}
        {{ return("view") }}
    {% elif strategy in ["delete+insert", "microbatch"]
        and unique_key is none %}
        {{ return("view") }}
    {% else %}
        {{ return("table") }}
    {% endif %}
{% endmacro %}


{% macro snowflake__create_table_as(
    temporary, relation, compiled_code,
    language='sql'
) -%}

{%- set catalog_relation =
    adapter.build_catalog_relation(config.model)
-%}

{#-- Non-Iceberg: delegate to native adapter
     so normal Snowflake tables are unaffected --#}
{%- if catalog_relation.catalog_type
    != 'BUILT_IN' -%}
    {{ return(dbt.snowflake__create_table_as(
        temporary, relation,
        compiled_code, language
    )) }}
    {%- endif -%}

    {#-- Iceberg BUILT_IN: inject type-safety --#}
    {%- if language != 'sql' -%}
    {% do exceptions.raise_compiler_error(
        'Iceberg is incompatible with '
        ~ language ~ ' models. '
        ~ 'Please use a SQL model.'
    ) %}
    {%- endif -%}

{%- set safe_compiled_code =
    iceberg_type_safe_wrap(compiled_code) -%}

    {%- if temporary -%}
    {{ snowflake__create_table_temporary_sql(
        relation, safe_compiled_code
    ) }}
{%- else -%}
    {{ snowflake__create_table_built_in_sql(
        relation, safe_compiled_code
    ) }}
    {%- endif -%}

{% endmacro %}


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
