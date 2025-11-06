{% macro get_deployed_models() %}
    {# 
      Returns a JSON array of successfully deployed model unique_ids
      Works even when run after dbt build (reads from target/run_results.json)
    #}
    {% set results_path = target.path ~ '/run_results.json' %}

    {% if not execute %}
        {{ return('[]') }}
    {% endif %}

    {% do log("Reading deployed models from: " ~ results_path, info=true) %}

    {% set results_data = load_file(results_path) | fromjson %}
    {% set deployed = [] %}

    {% for result in results_data.results %}
        {% if result.status == 'success' and result.node.resource_type == 'model' %}
            {% do deployed.append(result.node.unique_id) %}
        {% endif %}
    {% endfor %}

    {{ log("Deployed models found: " ~ deployed, info=true) }}
    {{ return(tojson(deployed)) }}
{% endmacro %}
