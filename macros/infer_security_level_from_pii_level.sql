{# ============================================================
   DPB-2846 — Infer SECURITY_LEVEL from PII_LEVEL

   Mapping (locked):
     L1, L2   -> RESTRICTED
     L3A, L3B -> HIGHLY_RESTRICTED

   Pure function. Raises a compiler error for unsupported values so a
   PII-tagged column can never leave SECURITY_LEVEL unset.
   ============================================================ #}
{% macro infer_security_level_from_pii_level(pii_level) %}
    {% set level = (pii_level | string | trim | upper) %}

    {% if level in ['L1', 'L2'] %}
        {{ return('RESTRICTED') }}
    {% elif level in ['L3A', 'L3B'] %}
        {{ return('HIGHLY_RESTRICTED') }}
    {% else %}
        {{ exceptions.raise_compiler_error(
            "Unsupported PII_LEVEL '" ~ pii_level
            ~ "'. Allowed values: L1, L2, L3A, L3B (DPB-2846)."
        ) }}
    {% endif %}
{% endmacro %}


{# ============================================================
   Resolve column snowflake_tags for Variant 2 tagging.

   Given a column's snowflake_tags dict:
     - If PII_LEVEL is present, derive SECURITY_LEVEL.
     - If SECURITY_LEVEL is also present and matches the derived value,
       keep it (idempotent).
     - If SECURITY_LEVEL is present and conflicts with the derived value,
       raise_compiler_error (hard-fail the dbt run).
     - If only SECURITY_LEVEL is present (no PII_LEVEL), leave tags as-is
       so non-PII restricted data can still be tagged directly.
   ============================================================ #}
{% macro resolve_column_snowflake_tags(column_tags, column_name=none, model_name=none) %}
    {% set resolved = {} %}
    {% for tag_name, tag_value in column_tags.items() %}
        {% do resolved.update({tag_name: tag_value}) %}
    {% endfor %}

    {% set ns = namespace(pii_key=none, security_key=none) %}
    {% for tag_name in column_tags.keys() %}
        {% if (tag_name | string | trim | upper) == 'PII_LEVEL' %}
            {% set ns.pii_key = tag_name %}
        {% elif (tag_name | string | trim | upper) == 'SECURITY_LEVEL' %}
            {% set ns.security_key = tag_name %}
        {% endif %}
    {% endfor %}

    {% if ns.pii_key is not none %}
        {% set inferred = cp_dbt_standard_package.infer_security_level_from_pii_level(column_tags[ns.pii_key]) %}
        {% set scope = '' %}
        {% if model_name is not none and column_name is not none %}
            {% set scope = " on " ~ model_name ~ "." ~ column_name %}
        {% elif column_name is not none %}
            {% set scope = " on column " ~ column_name %}
        {% endif %}

        {% if ns.security_key is not none %}
            {% set explicit = (column_tags[ns.security_key] | string | trim | upper) %}
            {% if explicit != inferred %}
                {{ exceptions.raise_compiler_error(
                    "SECURITY_LEVEL conflict" ~ scope
                    ~ ": explicit value '" ~ column_tags[ns.security_key]
                    ~ "' does not match SECURITY_LEVEL '" ~ inferred
                    ~ "' inferred from PII_LEVEL '" ~ column_tags[ns.pii_key]
                    ~ "'. Remove the conflicting SECURITY_LEVEL or change PII_LEVEL (DPB-2846)."
                ) }}
            {% endif %}
        {% else %}
            {% do resolved.update({'SECURITY_LEVEL': inferred}) %}
        {% endif %}
    {% endif %}

    {{ return(resolved) }}
{% endmacro %}
