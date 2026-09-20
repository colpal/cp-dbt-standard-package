{#
  Apply a Snowflake aggregation policy to a relation.

  Dual-path DDL for regular vs Iceberg tables:
    - Tries ALTER ICEBERG TABLE first (required for externally-managed Iceberg).
    - Falls back to ALTER TABLE (works for regular tables and Snowflake-managed
      Iceberg tables).

  Both ALTER statements are wrapped in nested EXECUTE IMMEDIATE strings so
  that syntax validation is deferred to runtime. Snowflake Scripting compiles
  all statements in a BEGIN/END block before executing — bare ALTER ICEBERG
  TABLE causes a compile-time error that EXCEPTION WHEN OTHER cannot catch.
  String-based dynamic SQL avoids this.

  IF EXISTS guards against missing relations; FORCE replaces any previously
  assigned aggregation policy.

  Args:
      relation: Target table (dbt Relation or identifier).
      policy_name: Aggregation policy to attach.
      entity_key_columns: Optional list of entity-key columns. When non-empty,
          emits ENTITY KEY ("COL1", "COL2"); omitted when empty.
#}
{% macro cp_apply_aggregation_policy(relation, policy_name, entity_key_columns=[]) -%}
    {%- if entity_key_columns -%}
        {%- set entity_key_clause -%}
 ENTITY KEY ({{ '"' }}{{ entity_key_columns|join('", "') }}{{ '"' }})
        {%- endset -%}
    {%- else -%}
        {%- set entity_key_clause = '' -%}
    {%- endif -%}

    {%- if execute -%}
        {{ log("cp_apply_aggregation_policy: attaching " ~ policy_name ~ " to " ~ relation, info=True) }}
    {%- endif -%}

    EXECUTE IMMEDIATE $$
    BEGIN
        EXECUTE IMMEDIATE 'ALTER ICEBERG TABLE IF EXISTS {{ relation }} SET AGGREGATION POLICY {{ policy_name }} {{ entity_key_clause }} FORCE';
    EXCEPTION
        WHEN OTHER THEN
            EXECUTE IMMEDIATE 'ALTER TABLE IF EXISTS {{ relation }} SET AGGREGATION POLICY {{ policy_name }} {{ entity_key_clause }} FORCE';
    END;
    $$;
{%- endmacro %}
