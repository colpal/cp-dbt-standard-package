{% macro upload_artifacts_on_run_end(results) %}
    {% set artifacts_db = env_var('DBT_ARTIFACTS_DATABASE', '') %}
    {% set artifacts_schema = env_var('DBT_ARTIFACTS_SCHEMA', '') %}

    {% if not artifacts_db or not artifacts_schema %}
        {% do return(None) %}
    {% endif %}

    {{ log("Uploading dbt artifacts to " ~ artifacts_db ~ "." ~ artifacts_schema, info=true) }}

    {{ run_query("USE DATABASE " ~ artifacts_db) }}
    {{ run_query("USE SCHEMA " ~ artifacts_schema) }}

    {{ dbt_artifacts.upload_results(results) }}

    {% do return(None) %}
{% endmacro %}
