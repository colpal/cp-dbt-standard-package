{% materialization  iceberg_table, default %}
{# Getting settings from model #}
    {% set catalog = model.config.get('catalog', 'SNOWFLAKE') %}
    {% set external_volume = model.config.get('external_volume', var('default_external_volume')) %}
    {% if external_volume == '' or external_volume == None %}
        {% set external_volume = var('default_external_volume') %}
    {% endif %}
    {% set clustering_key = model.config.get('clustering_key', None) %}
    {% set unique_key = model.config.get('unique_key', None) %}
    {# set base_location = model.config.get('base_location', 'default_base_location') #}    
    {# set base_location = {{ this.schema }}/{{model}} #}
    {% set temp_view_name = this.identifier ~ '_TEMP_VIEW' %}

    {{ run_hooks(pre_hooks) }}
    {# Creating view with SQL definition from model to be used for schema evolution purposes #}    
    {% set create_temp_view_sql %}
        CREATE OR REPLACE TEMP VIEW {{ this.database}}.{{ this.schema }}.{{ temp_view_name }} AS {{ sql }}
    {% endset %}
    {# Run view creation query #}
    {{ run_query(create_temp_view_sql) }}
    {# Query to collect column names from view to be used for schema evolution purposes #}
    {% set desc_temp_view_sql %}
        DESCRIBE VIEW {{ this.database}}.{{ this.schema }}.{{ temp_view_name }} 
    {% endset %}    
    {# Check if the table already exists #}
    {% set existing_relation = adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    {% set is_incremental = existing_relation is not none %}

    {# Check if there is cluster keys defined in model#}
        {%- if clustering_key is not none and clustering_key is string -%}
        {%- set clustering_key = [clustering_key] -%}
    {%- endif -%}
    {%- if clustering_key is not none -%}
        {%- set clustering_key = clustering_key|join(", ")-%}
    {% else %}
        {%- set clustering_key = none -%}
    {%- endif -%}

    {# Check if incremental logic to be executed #}
    {% if is_incremental %}
    {% set describe_result = run_query(desc_temp_view_sql) %}  
    {% set temp_view_columns = describe_result %}
    {#{ log("TEMP VIEW COLUMNS: " ~ temp_view_columns| map(attribute='name') | join(', '), info=True ) }#}    
    {% set target_relation = adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    {% set target_columns = adapter.get_columns_in_relation(target_relation) %}
    {#{ log("TARGET COLUMNS: " ~ target_columns | map(attribute='name') | join(', '), info=True) }#}
    {% set source_not_in_target = diff_columns(temp_view_columns, target_columns) %}
    {% set target_drop_table = api.Relation.create(database=this.database, schema=this.schema, identifier=this.identifier) %}
    {% set view_drop_table = api.Relation.create(database=this.database, schema=this.schema, identifier=temp_view_name) %}
    {% set missing_columns = adapter.get_missing_columns(target_drop_table, view_drop_table) %}
    {{ log("COLUMNS TO ADD: " ~ source_not_in_target | map(attribute='name') | join(', '), info=True) }}    
    {# set target_not_in_source = diff_columns((target_columns | map(attribute='name') | join(', ')), (temp_view_columns | map(attribute='name') | join(', '))) #}
    {#% set target_not_in_source = diff_columns(target_columns, temp_view_columns) %#}
    {{ log("COLUMNS TO DROP: " ~ missing_columns | map(attribute='name') | join(', '), info=True) }}     

    {# Run query to add columns #}   
        {% if source_not_in_target | length > 0 %}
        {% set alter_add_columns %}
            ALTER ICEBERG TABLE {{ this }} ADD COLUMN 
                {% for col in source_not_in_target %}
                    {{ col.name }} {{ data_type_mapping(col.type) }}{% if not loop.last %}, {% endif %}
                {% endfor %}
        {% endset %}
        {{ run_query(alter_add_columns) }}
        {% endif %}

    {# Run query to drop columns #} 
    {% if missing_columns %}
            {% set alter_drop_columns %}
            ALTER ICEBERG TABLE {{ this }} DROP
                {% for col in missing_columns %}
                    {{ col.name}}{% if not loop.last %}, {% endif %}
                {% endfor %}
            {% endset %}
        {{ run_query(alter_drop_columns) }}
        {% endif %}
{% endif %}

{#-Full refresh or new table creation #}
    {% if not is_incremental %}
        {# % set create_refresh_statement % #}
        {% call statement('main', fetch_result=True) %}
            CREATE OR REPLACE ICEBERG TABLE {{ this }}
            CATALOG = {{ catalog }}
            EXTERNAL_VOLUME = {{ external_volume }}
            BASE_LOCATION = "{{ this.schema }}/{{model.name}}"
            {% if clustering_key != '' and not temporary -%}
            CLUSTER BY ({{clustering_key}})
            {%- endif -%}
            AS {{ sql }}
        {# % endset % #}
        {% endcall %}
        {{ log("Creating Iceberg table in external volume: " ~ external_volume ~ " with catalog: " ~ catalog, info=True) }}
        {# { run_query(create_refresh_statement) } #}


    {% elif is_incremental %}

        {% if unique_key %}

            {# % set merge_statement % #}
            {% call statement('main', fetch_result=True) %}
                MERGE INTO {{ this }} AS target
                USING (
                    {{ sql }} 
                ) AS source
                ON target.{{ unique_key }} = source.{{ unique_key }}
                WHEN MATCHED THEN
                    UPDATE SET {{ cp_dbt_standard_package.iceberg_update_columns('source', 'target', temp_view_name)}} 
                WHEN NOT MATCHED THEN
                    INSERT ({{ cp_dbt_standard_package.iceberg_insert_columns(temp_view_name) }})
                    VALUES ({{ cp_dbt_standard_package.iceberg_insert_values('source', temp_view_name) }});
            {#% endset %#}
            {% endcall %}
            {# % set merge_result = run_query(merge_statement) % #}
            {# % set merge_result = load_result('main') % #}
            {# % set rows_affected = merge_result.rows_affected % #}

            {% set rows_affected = run_query("SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))") %}
            {% for row in rows_affected.rows %}
            {{ log('Number of Records Updated: ' ~ row[1] ~ '. Number of Records Inserted: ' ~ row[0], info=True)}}
            {% endfor %}
            {#{ log("Incremental merge completed with rows affected = " ~ row, info=True) } #}
        {% else %}

            {# % set insert_statement % #}
            {% call statement('main', fetch_result=True) %}
                INSERT INTO {{ this }}
                {{ sql }}
            {# % endset % #}
            {% endcall %}
            {# % set insert_result = run_query(insert_statement) % #}
            {# % set rows_affected = insert_result.rows_affected % #}
            {% set rows_affected = run_query("SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))") %}
            {% for row in rows_affected.rows %}
            {{ log('Number of Records Inserted: ' ~ row[0] , info=True)}}
            {% endfor %}
            {# { log("Incremental insert completed with rows affected = " ~ insert_result.rows_affected, info=True) } #}
        {% endif %}

        {% if clustering_key != '' and not temporary -%}
            {{ log("Clustering key in incremental statement = " ~ clustering_key, info=True)}}
            {% set create_table_cluster %}
                ALTER ICEBERG TABLE {{ this }} CLUSTER BY ({{clustering_key}})
            {% endset %}
            {{ run_query(create_table_cluster) }}
        {%- endif -%}
        {% if enable_automatic_clustering and clustering_key != '' and not temporary  -%}
            {% set create_table_cluster %}
                ALTER ICEBERG TABLE {{ this }} RESUME RECLUSTER
            {% endset %}
            {{ run_query(create_table_cluster) }}
        {%- endif -%}
    {% endif %}

    {# Drop temp view when finished #}
    {% set drop_temp_view_sql %}
        DROP VIEW  {{ this.database}}.{{ this.schema }}.{{ temp_view_name}};
    {% endset %}
    {#{ run_query(drop_temp_view_sql)}#}

    {{ run_hooks(post_hooks) }}

    {{ return({
        "state": "success",
        "relations": [this]
    }) }}
{% endmaterialization %}
