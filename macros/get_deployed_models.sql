{% macro get_deployed_models(results) %}
    {# 
      Returns a JSON list of successfully deployed model unique_ids 
      so it can be passed to tagging macro or logged.
    #}
    {% set deployed = [] %}
    {% for r in results %}
        {% if r.status == 'success' and r.node.resource_type == 'model' %}
            {% do deployed.append(r.node.unique_id) %}
        {% endif %}
    {% endfor %}
    {{ return(tojson(deployed)) }}
{% endmacro %}
