{#
  Apply a Snowflake aggregation policy to a relation.

  Dual-path DDL for regular vs Iceberg tables during Iceberg rollout:
  tries ALTER ICEBERG TABLE IF EXISTS first, then on exception falls back
  to ALTER TABLE IF EXISTS. Callers do not need to know the table type
  (no cp_is_iceberg / iceberg_overrides dependency).

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
        ALTER ICEBERG TABLE IF EXISTS {{ relation }}
            SET AGGREGATION POLICY {{ policy_name }}{{ entity_key_clause }} FORCE;
        RETURN 'SUCCESS: applied aggregation policy {{ policy_name }} to ICEBERG table {{ relation }}';
    EXCEPTION
        WHEN OTHER THEN
            ALTER TABLE IF EXISTS {{ relation }}
                SET AGGREGATION POLICY {{ policy_name }}{{ entity_key_clause }} FORCE;
            RETURN 'SUCCESS: applied aggregation policy {{ policy_name }} to regular table {{ relation }} (fallback)';
    END;
    $$;
{%- endmacro %}
