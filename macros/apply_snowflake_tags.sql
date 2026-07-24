{#
  Snowflake Tagging Package (`dbt_snowflake_tagging`)
  ----------------------------------------------------
    A set of macros to apply centrally created Snowflake tags to dbt models and columns
    based on configurations in schema YAML files.

  Version: 1.0.0

  ---------------- How to use ----------------

  1. Update packages.yml and enable post-run hook as outlined in readme.

  2. Usage - Define Tags on Models (in your model's `.yml` file):
     models:
       - name: my_model
         config:
           snowflake_tags:
             IS_CERTIFIED: 'TRUE'
         columns:
           - name: column_name
             meta:
               snowflake_tags:
                 TAG_NAME: 'tag_value_a'

  -----------------------------------------------
#}

/*
    Snowflake tagging macros
*/

-- set central tag schema
{# ============================================================
   Snowflake Tagging Package
   Updated to log Snowflake tags ONCE only
   ============================================================ #}



-- set central tag schema
{% macro get_tag_config() %}
    {% set config = {
        'tag_database': 'OPS_CUR',
        'tag_schema': 'TAGS'
    } %}
    {{ return(config) }}
{% endmacro %}

{# ============================================================
   RESOLVE TAGGING ROLE
   Tag DDL must run as the role that owns the target object.
   Uses the target database name (not just target.role) so a
   CUR-session tagging CON-layer objects switches to CON, and a
   CUR-session tagging CUR-layer objects (e.g. iceberg tables in
   _PR_{N}_{DOMAIN}_CUR) does NOT switch. Iceberg tables enforce
   strict OWNERSHIP for ALTER SET TAG, which is what surfaced this
   bug in DPB-2591.

   Layer inference (see data-platforms-infrastructure AGENTS.md):
     {DOMAIN}_CUR / {DOMAIN}_CON                  (prod)
     {DOMAIN}_CUR_PD / {DOMAIN}_CON_PD            (pre-deploy)
     _PR_{N}_{DOMAIN}_CUR / _PR_{N}_{DOMAIN}_CON  (PR preview)
   -> a trailing `_CON` or `_CON_PD` means CON layer; anything else CUR.
   Returns none if no switch is needed.
   ============================================================ #}
{% macro get_tagging_role(database_nm) %}
    {% set current_role = target.role | upper %}
    {% set db_upper = database_nm | upper %}
    {% set is_con_layer = db_upper.endswith('_CON') or db_upper.endswith('_CON_PD') %}

    {% if is_con_layer and '_DEPLOY_CUR' in current_role %}
        {{ return(current_role | replace('_DEPLOY_CUR', '_DEPLOY_CON')) }}
    {% elif (not is_con_layer) and '_DEPLOY_CON' in current_role %}
        {{ return(current_role | replace('_DEPLOY_CON', '_DEPLOY_CUR')) }}
    {% endif %}
    {{ return(none) }}
{% endmacro %}

-- retrieve all available Snowflake tags from central schema
{% macro get_snowflake_tags(show_log=false) %}

    {% set config = cp_dbt_standard_package.get_tag_config() %}

    {% set sql %}
        SHOW TAGS IN SCHEMA {{ config.tag_database }}.{{ config.tag_schema }}
    {% endset %}

    {% set rows = run_query(sql) %}
    {% set tag_list = [] %}

    {% if execute %}
        {% for row in rows %}
            {% set tag_name = row["name"] | string %}
            {% set allowed_vals_str = row["allowed_values"] | string if row["allowed_values"] is not none else "" %}

            {% set allowed_values = [] %}
            {% if allowed_vals_str.startswith("[") %}
                {% set cleaned = allowed_vals_str.strip("[]") %}
                {% for item in cleaned.split(",") %}
                    {% set clean = item | replace('"', '') | trim %}
                    {% if clean %}
                        {% do allowed_values.append(clean) %}
                    {% endif %}
                {% endfor %}
            {% endif %}

            {% do tag_list.append({
                'tag_name': tag_name,
                'allowed_values': allowed_values
            }) %}
        {% endfor %}
    {% endif %}

    {% if show_log %}
        {{ log("Available Snowflake Tags:", info=true) }}
        {% for tag in tag_list %}
            {{ log(" - " ~ tag.tag_name ~ " (allowed values: " ~ tag.allowed_values ~ ")", info=true) }}
        {% endfor %}
    {% endif %}

    {{ return(tag_list) }}

{% endmacro %}


{# ============================================================
   APPLY TAG TO MODEL
   Supports: .strip() whitespace handling, optional relation_type (skip DB query),
   optional is_iceberg (skip adapter.get_relation query when caller already knows)
   ============================================================ #}
{% macro apply_tag(database_nm, schema, identifier, tag_name, tag_value, relation_type=none, is_iceberg=none) %}

    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags(show_log=false) %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {# Does the tag exist? #}
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}

    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Skipping.", info=true) }}
        {{ return() }}
    {% endif %}

    {% set tag_name = ns.matching_tag %}

    {# Validate allowed values #}
    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}

        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value.strip() | upper == tag_value.strip() | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}

        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not allowed for tag '" ~ tag_name ~ "'.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}

        {% set tag_value = val_ns.matched_value %}
    {% endif %}

    {# Identify relation type and Iceberg format.
       When the caller (tag_models_on_run_end) passes both relation_type and
       is_iceberg, we skip the adapter.get_relation() Snowflake metadata query
       entirely — saving one network round-trip per tag application.
       Fallback: if is_iceberg is not provided, query Snowflake as before. #}
    {% if is_iceberg is none or not relation_type %}
        {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
        {% if not relation_type %}
            {% set relation_type = relation.type | upper if relation else 'TABLE' %}
        {% endif %}
        {% if is_iceberg is none %}
            {% set is_iceberg = (relation.is_iceberg_format if relation else false) %}
        {% endif %}
    {% endif %}

    {# Iceberg tables require ALTER ICEBERG TABLE syntax #}
    {% set ddl_prefix = 'ICEBERG ' if is_iceberg else '' %}
    {# --------------------------------------------------------
       Role switch: tag DDL must run as {domain}_DEPLOY_CON,
       not {domain}_DEPLOY_CUR. Switch only if needed, and
       always restore the session role afterwards.
       -------------------------------------------------------- #}
    {% set original_role = target.role | upper %}
    {% set tagging_role = cp_dbt_standard_package.get_tagging_role(database_nm) %}

    {% if tagging_role %}
        {{ log("Switching role " ~ original_role ~ " -> " ~ tagging_role ~ " for tag DDL", info=true) }}
        {% do run_query('USE ROLE ' ~ tagging_role) %}
    {% endif %}
  
    {# Apply tag #}
    {% set sql %}
      ALTER {{ ddl_prefix }}{{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to " ~ schema ~ "." ~ identifier, info=true) }}

    {# Restore original session role #}
    {% if tagging_role %}
        {% do run_query('USE ROLE ' ~ original_role) %}
    {% endif %}
  
{% endmacro %}


{# ============================================================
   APPLY COLUMN TAG
   Supports: .strip() whitespace handling, optional relation_type (skip DB query),
   optional is_iceberg (skip adapter.get_relation query when caller already knows)
   ============================================================ #}
{% macro apply_column_tag(database_nm, schema, identifier, column_name, tag_name, tag_value, relation_type=none, is_iceberg=none) %}

    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags(show_log=false) %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}

    {% if not ns.tag_exists %}
        {{ log("ERROR: Column tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Skipping.", info=true) }}
        {{ return() }}
    {% endif %}

    {% set tag_name = ns.matching_tag %}

    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}

        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value.strip() | upper == tag_value.strip() | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}

        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not allowed for column tag '" ~ tag_name ~ "'.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}

        {% set tag_value = val_ns.matched_value %}
    {% endif %}

    {# Identify relation type and Iceberg format — same optimization as apply_tag. #}
    {% if is_iceberg is none or not relation_type %}
        {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
        {% if not relation_type %}
            {% set relation_type = relation.type | upper if relation else 'TABLE' %}
        {% endif %}
        {% if is_iceberg is none %}
            {% set is_iceberg = (relation.is_iceberg_format if relation else false) %}
        {% endif %}
    {% endif %}

    {# Iceberg tables require ALTER ICEBERG TABLE syntax #}
    {% set ddl_prefix = 'ICEBERG ' if is_iceberg else '' %}
    {# --------------------------------------------------------
       Role switch: tag DDL must run as {domain}_DEPLOY_CON,
       not {domain}_DEPLOY_CUR. Switch only if needed, and
       always restore the session role afterwards.
       -------------------------------------------------------- #}
    {% set original_role = target.role | upper %}
    {% set tagging_role = cp_dbt_standard_package.get_tagging_role(database_nm) %}
    {% if tagging_role %}
        {{ log("Switching role " ~ original_role ~ " -> " ~ tagging_role ~ " for tag DDL", info=true) }}
        {% do run_query('USE ROLE ' ~ tagging_role) %}
    {% endif %}
  
    {% set sql %}
      ALTER {{ ddl_prefix }}{{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      MODIFY COLUMN {{ column_name }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Applied column tag '" ~ tag_name ~ "' to " ~ column_name ~ " in " ~ schema ~ "." ~ identifier, info=true) }}

    {# Restore original session role #}
    {% if tagging_role %}
        {% do run_query('USE ROLE ' ~ original_role) %}
    {% endif %}
  
{% endmacro %}


{# ============================================================
   PROCESS TAGGING AT END OF RUN
   Supports: alias, materialization-based relation type, dual tag location (config/meta)
   ============================================================ #}
{% macro tag_models_on_run_end(changed_models=None) %}
    {{ log("Starting tag application process", info=true) }}

    {% if changed_models is string %}
        {% set changed_models = fromjson(changed_models) %}
    {% endif %}

    {% if not changed_models or changed_models | length == 0 %}
        {{ log("No changed_models provided — skipping tagging.", info=true) }}
        {% set models_to_tag = [] %}
    {% else %}
        {{ log("Applying tags to deployed models: " ~ changed_models, info=true) }}
        {% set models_to_tag = changed_models %}
    {% endif %}

    {% for node_id in models_to_tag %}
        {% if node_id in graph.nodes %}
            {% set node = graph.nodes[node_id] %}

            {% if node.resource_type == 'model' %}
                {% set model_database = node.database %}
                {% set model_schema = node.schema %}
                {% set model_name = node.alias | default(node.name) %}

                {# Determine relation type from materialization config #}
                {% set mat = node.config.materialized %}
                {% set rel_type = 'VIEW' if mat == 'view' else 'TABLE' %}

                {# Detect Iceberg from dbt config — avoids querying Snowflake
                   metadata (adapter.get_relation) for every tag application.
                   A model is Iceberg if table_format='iceberg' or catalog_name is set. #}
                {% set model_is_iceberg = (node.config.get('table_format', '') == 'iceberg')
                    or (node.config.get('catalog_name', '') | length > 0) %}

                {{ log("Processing model: " ~ model_database ~ "." ~ model_schema ~ "." ~ model_name ~ (" [iceberg]" if model_is_iceberg else ""), info=true) }}

                {# Table-level tags — check both config.snowflake_tags and config.meta.snowflake_tags #}
                {% set model_tags = node.config.get('snowflake_tags', {}) %}
                {% set meta_tags = node.config.get('meta', {}).get('snowflake_tags', {}) %}

                {% if meta_tags %}
                    {% for tag_name, tag_value in meta_tags.items() %}
                        {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value, rel_type, model_is_iceberg) }}
                    {% endfor %}
                {% elif model_tags %}
                    {% for tag_name, tag_value in model_tags.items() %}
                        {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value, rel_type, model_is_iceberg) }}
                    {% endfor %}
                {% endif %}

                {# Column-level tags #}
                {% for col_name, col in node.columns.items() %}
                    {% if col.meta is defined and col.meta.snowflake_tags is defined %}
                        {% for tag_name, tag_value in col.meta.snowflake_tags.items() %}
                            {{ cp_dbt_standard_package.apply_column_tag(model_database, model_schema, model_name, col_name, tag_name, tag_value, rel_type, model_is_iceberg) }}
                        {% endfor %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {{ log("Tag application process completed.", info=true) }}
{% endmacro %}


{# ============================================================
   AUTO-TAG FROM RUN RESULTS (on-run-end)
   Called automatically by on-run-end hook to reapply tags after dbt runs
   ============================================================ #}
{% macro tag_models_from_results() %}
    {% if execute %}
        {% set successful_models = [] %}
        {% for res in results %}
            {% if res.node.resource_type == 'model' and res.status in ['success', 'pass'] %}
                {% do successful_models.append(res.node.unique_id) %}
            {% endif %}
        {% endfor %}

        {% if successful_models | length > 0 %}
            {{ log("Auto-tagging " ~ successful_models | length ~ " deployed model(s)", info=true) }}
            {{ cp_dbt_standard_package.tag_models_on_run_end(successful_models) }}
        {% else %}
            {{ log("No successfully deployed models to tag.", info=true) }}
        {% endif %}
    {% endif %}
{% endmacro %}


{# ============================================================
   CALL CERTIFIED READ PROCEDURE (on-run-end)

   Zero-latency, domain-scoped alternative to the hourly
   TAG_BASED_RBAC_CERT_PROC task.

   Instead of querying SNOWFLAKE.ACCOUNT_USAGE (latency up to 2h),
   this macro reads the dbt graph at runtime to build a complete
   manifest of certified objects, then passes it directly to the
   stored procedure as a JSON string.

   Domain segregation is enforced: one CALL per target database,
   so FIN_CON models cannot trigger grants on MD_CON, etc.

   Guard: only fires when the Snowflake session role contains 'DEPLOY'
   (e.g. EX_DEPLOY_CUR, FIN_DEPLOY_CON). This prevents the procedure
   from being called during local developer or analyst runs.

   The legacy 0-arg GRANT_CERTIFIED_READ_ACCESS() procedure continues
   to run on its hourly Snowflake Task, acting as a safety net for
   objects tagged directly in Snowflake (outside of dbt runs).
   ============================================================ #}
{% macro call_certified_read_proc() %}
    {% if execute %}

        {# ---------------------f-----------------------------------
           Role guard: fire for DEPLOY roles (CI/CD) and ELT roles (Airflow).
           Both can rebuild models (DROP + CREATE) which wipes all Snowflake
           object-level grants including CROSS_DOMAIN_READ.SELECT. The proc must
           run on-run-end to reapply grants immediately rather than waiting
           up to 60 min for the hourly GRANT_CERTIFIED_READ_ACCESS task.

           ELT safety: execute_as = OWNER on the proc means the actual GRANT
           DDL runs as the OPS owner — not the ELT role itself. ELT only
           needs EXECUTE (USAGE) on the procedure.
           -------------------------------------------------------- #}
        {% set role_upper = target.role | upper %}
        {% if 'DEPLOY' in role_upper or 'ELT' in role_upper %}


        {# --------------------------------------------------------
           Step 1: Walk the full graph and collect every certified model,
           grouped by its resolved target database.

           Always runs — even in PR/PD environments — so CI logs show
           exactly which domains and objects would have grants applied
           (dry-run visibility). The actual CALL is gated separately.

           We iterate ALL nodes (not just `results`) so the manifest
           always contains the complete certified set, including models
           not rebuilt in this run but whose grants must remain active.
           -------------------------------------------------------- #}
        {% set certified_read_by_db = {} %}
        {% for node_id, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {# Resolve CERTIFIED_READ from either tag location:
                - config.snowflake_tags (set via dbt model config)
                - config.meta.snowflake_tags (set via meta block) #}
                {% set model_tags  = node.config.get('snowflake_tags', {}) %}
                {% set meta_tags   = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                {% set certified_read = false %}
                {% if model_tags.get('IS_CERTIFIED', '') | upper == 'TRUE' %}
                    {% set certified_read = true %}
                {% elif meta_tags.get('IS_CERTIFIED', '') | upper == 'TRUE' %}
                    {% set certified_read = true %}
                {% endif %}
                {% if certified_read %}
                    {% set db = node.database | upper %}
                    {# Normalize ephemeral env suffixes back to the production database name:
                    EX_CON_PD      -> EX_CON
                    EX_CON_PR_123  -> EX_CON #}
                    {% if '_PR_' in db %}
                        {% set db = db.split('_PR_')[0] %}
                    {% elif db.endswith('_PD') %}
                        {% set db = db[:-3] %}
                    {% endif %}
                    {% set mat = node.config.materialized %}
                    {% set obj_type = 'VIEW' if mat == 'view' else 'TABLE' %}
                    {% if db not in certified_read_by_db %}
                        {% do certified_read_by_db.update({db: []}) %}
                    {% endif %}
                    {% do certified_read_by_db[db].append({
                        'schema': node.schema | upper,
                        'name':   (node.config.get('alias') or node.name) | upper,
                        'type':   obj_type
                    }) %}
                {% endif %}
            {% endif %}
        {% endfor %}

        {# --------------------------------------------------------
           Step 2: Call GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN once per
           domain database, passing the scoped JSON manifest.

           In PR / PD environments: log the manifest as a dry run only.
           No CALL is made -- the hourly task is the safety net for
           ephemeral environments.

           In production: execute the CALL.
           -------------------------------------------------------- #}
        {% set db_upper = target.database | upper %}
        {% set is_ephemeral = '_PR_' in db_upper or db_upper.endswith('_PD') %}
        {% set github_event = env_var('GITHUB_EVENT_NAME', '') | lower %}
        {% set is_push_merge = github_event in ['push', 'merge_group'] %}

        {% if certified_read_by_db | length > 0 %}
            {% if not is_push_merge %}
                {# ── DRY RUN (PR / non-merge event): log what production would do, no CALL issued ── #}
                {{ log(
                    "[certified_read_grants] DRY RUN | event: " ~ (github_event if github_event else 'unknown/local')
                    ~ " | env: " ~ target.database
                    ~ " | role: " ~ target.role
                    ~ " | The following domain(s) would have GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN"
                    ~ " called if this were a push/merge run:",
                    info=true
                ) }}
                {% for domain_db, objects in certified_read_by_db.items() %}
                    {{ log(
                        "[certified_read_grants]   domain: " ~ domain_db
                        ~ "  certified read: " ~ objects | length,
                        info=true
                    ) }}
                {% endfor %}
                {{ log(
                    "[certified_read_grants] No grants issued — pull request runs do not hold CERTIFIED_READ grants."
                    ~ " The hourly TAG_BASED_RBAC_CERTIFIED_READ_PROC task is the safety net for this environment.",
                    info=true
                ) }}
            {% else %}
                {# ── PUSH/MERGE (production): call the proc once per domain ── #}
                {# Role switch: the grant proc must run as {domain}_DEPLOY_CON,
                not {domain}_DEPLOY_CUR. Switch once for the whole loop and
                always restore the session role afterwards. #}
                {% set original_role = target.role | upper %}
                {% set grant_role = cp_dbt_standard_package.get_tagging_role() %}
                {% if grant_role %}
                    {{ log(
                        "[certified_read_grants] Switching role " ~ original_role
                        ~ " -> " ~ grant_role ~ " for grant proc calls",
                        info=true
                    ) }}
                    {% do run_query('USE ROLE ' ~ grant_role) %}
                {% endif %}

                {% for domain_db, objects in certified_read_by_db.items() %}
                    {% set json_payload = tojson(objects) %}
                    {{ log(
                        "[certified_read_grants] CALLING | event: " ~ github_event
                        ~ " | domain: " ~ domain_db
                        ~ " | certified read objects: " ~ objects | length
                        ~ " | role: " ~ (grant_role if grant_role else original_role),
                        info=true
                    ) }}
                    {% set call_sql %}
                        CALL OPS_CUR.UTIL_COMMON.GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN(
                            '{{ domain_db }}',
                            '{{ json_payload | replace("'", "\'") }}')
                    {% endset %}
                    {% do run_query(call_sql) %}
                {% endfor %}

                {# Restore original session role #}
                {% if grant_role %}
                    {% do run_query('USE ROLE ' ~ original_role) %}
                {% endif %}
            {% endif %}
        {% else %}
            {% if not is_push_merge %}
                {{ log(
                    "[certified_read_grants] SKIPPED | event: " ~ (github_event if github_event else 'unknown/local')
                    ~ " | env: " ~ target.database
                    ~ " | No certified read models found targeting production databases."
                    ~ " In PR/PD runs, all node.database values resolve to ephemeral databases"
                    ~ " (_PR_*/_PD) and are excluded from grant processing by design.",
                    info=true
                ) }}
            {% else %}
                {{ log(
                    "[certified_read_grants] SKIPPED | No models with CERTIFIED_READ=TRUE found in the dbt graph."
                    ~ " Verify that cross domain models have snowflake_tags: {CERTIFIED_READ: 'TRUE'} in their config.",
                    info=true
                ) }}
            {% endif %}
        {% endif %} {# certified_read_by_db length check #}

        {% else %}
            {{ log(
                "[certified_read_grants] SKIPPED | role: '" ~ target.role
                ~ "' is not a DEPLOY or ELT role — cross domain grant reconciliation only runs"
                ~ " for deployment and Airflow pipeline roles to prevent analyst runs from"
                ~ " triggering privilege changes.",
                info=true
            ) }}
        {% endif %} {# DEPLOY / ELT role guard #}

    {% endif %}
{% endmacro %}

{# ============================================================
   CALL CROSS_DOMAIN READ PROCEDURE (on-run-end)

   Zero-latency, domain-scoped alternative to the hourly
   TAG_BASED_RBAC_CROSS_DOMAIN_PROC task.

   Instead of querying SNOWFLAKE.ACCOUNT_USAGE (latency up to 2h),
   this macro reads the dbt graph at runtime to build a complete
   manifest of certified objects, then passes it directly to the
   stored procedure as a JSON string.

   Domain segregation is enforced: one CALL per target database,
   so FIN_CON models cannot trigger grants on MD_CON, etc.

   Guard: only fires when the Snowflake session role contains 'DEPLOY'
   (e.g. EX_DEPLOY_CUR, FIN_DEPLOY_CON). This prevents the procedure
   from being called during local developer or analyst runs.

   The legacy 0-arg GRANT_CROSS_DOMAIN_READ_ACCESS() procedure continues
   to run on its hourly Snowflake Task, acting as a safety net for
   objects tagged directly in Snowflake (outside of dbt runs).
   ============================================================ #}
{% macro call_cross_domain_read_proc() %}
    {% if execute %}

        {# --------------------------------------------------------
           Role guard: fire for DEPLOY roles (CI/CD) and ELT roles (Airflow).
           Both can rebuild models (DROP + CREATE) which wipes all Snowflake
           object-level grants including CROSS_DOMAIN_READ.SELECT. The proc must
           run on-run-end to reapply grants immediately rather than waiting
           up to 60 min for the hourly GRANT_CROSS_DOMAIN_READ_ACCESS task.

           ELT safety: execute_as = OWNER on the proc means the actual GRANT
           DDL runs as the OPS owner — not the ELT role itself. ELT only
           needs EXECUTE (USAGE) on the procedure.
           -------------------------------------------------------- #}
        {% set role_upper = target.role | upper %}
        {% if 'DEPLOY' in role_upper or 'ELT' in role_upper %}


        {# --------------------------------------------------------
           Step 1: Walk the full graph and collect every certified model,
           grouped by its resolved target database.

           Always runs — even in PR/PD environments — so CI logs show
           exactly which domains and objects would have grants applied
           (dry-run visibility). The actual CALL is gated separately.

           We iterate ALL nodes (not just `results`) so the manifest
           always contains the complete certified set, including models
           not rebuilt in this run but whose grants must remain active.
           -------------------------------------------------------- #}
        {% set cross_domain_by_db = {} %}
        {% for node_id, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {# Resolve CROSS_DOMAIN from either tag location:
                - config.snowflake_tags (set via dbt model config)
                - config.meta.snowflake_tags (set via meta block) #}
                {% set model_tags  = node.config.get('snowflake_tags', {}) %}
                {% set meta_tags   = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                {% set cross_domain = false %}
                {% if model_tags.get('CROSS_DOMAIN', '') | upper == 'TRUE' %}
                    {% set cross_domain = true %}
                {% elif meta_tags.get('CROSS_DOMAIN', '') | upper == 'TRUE' %}
                    {% set cross_domain = true %}
                {% endif %}
                {% if cross_domain %}
                    {% set db = node.database | upper %}
                    {# Normalize ephemeral env suffixes back to the production database name:
                    EX_CON_PD      -> EX_CON
                    EX_CON_PR_123  -> EX_CON #}
                    {% if '_PR_' in db %}
                        {% set db = db.split('_PR_')[0] %}
                    {% elif db.endswith('_PD') %}
                        {% set db = db[:-3] %}
                    {% endif %}
                    {% set mat = node.config.materialized %}
                    {% set obj_type = 'VIEW' if mat == 'view' else 'TABLE' %}
                    {% if db not in cross_domain_by_db %}
                        {% do cross_domain_by_db.update({db: []}) %}
                    {% endif %}
                    {% do cross_domain_by_db[db].append({
                        'schema': node.schema | upper,
                        'name':   (node.config.get('alias') or node.name) | upper,
                        'type':   obj_type
                    }) %}
                {% endif %}
            {% endif %}
        {% endfor %}

        {# --------------------------------------------------------
           Step 2: Call GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN once per
           domain database, passing the scoped JSON manifest.

           In PR / PD environments: log the manifest as a dry run only.
           No CALL is made -- the hourly task is the safety net for
           ephemeral environments.

           In production: execute the CALL.
           -------------------------------------------------------- #}
        {% set db_upper = target.database | upper %}
        {% set is_ephemeral = '_PR_' in db_upper or db_upper.endswith('_PD') %}
        {% set github_event = env_var('GITHUB_EVENT_NAME', '') | lower %}
        {% set is_push_merge = github_event in ['push', 'merge_group'] %}

        {% if cross_domain_by_db | length > 0 %}
            {% if not is_push_merge %}
                {# ── DRY RUN (PR / non-merge event): log what production would do, no CALL issued ── #}
                {{ log(
                    "[cross_domain_grants] DRY RUN | event: " ~ (github_event if github_event else 'unknown/local')
                    ~ " | env: " ~ target.database
                    ~ " | role: " ~ target.role
                    ~ " | The following domain(s) would have GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN"
                    ~ " called if this were a push/merge run:",
                    info=true
                ) }}
                {% for domain_db, objects in cross_domain_by_db.items() %}
                    {{ log(
                        "[cross_domain_grants]   domain: " ~ domain_db
                        ~ "  cross domain objects: " ~ objects | length,
                        info=true
                    ) }}
                {% endfor %}
                {{ log(
                    "[cross_domain_grants] No grants issued — pull request runs do not hold CROSS_DOMAIN_READ grants."
                    ~ " The hourly TAG_BASED_RBAC_CROSS_DOMAIN_PROC task is the safety net for this environment.",
                    info=true
                ) }}
            {% else %}
                {# ── PUSH/MERGE (production): call the proc once per domain ── #}
                {# Role switch: the grant proc must run as {domain}_DEPLOY_CON,
                not {domain}_DEPLOY_CUR. Switch once for the whole loop and
                always restore the session role afterwards. #}
                {% set original_role = target.role | upper %}
                {% set grant_role = cp_dbt_standard_package.get_tagging_role() %}
                {% if grant_role %}
                    {{ log(
                        "[cross_domain_grants] Switching role " ~ original_role
                        ~ " -> " ~ grant_role ~ " for grant proc calls",
                        info=true
                    ) }}
                    {% do run_query('USE ROLE ' ~ grant_role) %}
                {% endif %}

                {% for domain_db, objects in cross_domain_by_db.items() %}
                    {% set json_payload = tojson(objects) %}
                    {{ log(
                        "[cross_domain_grants] CALLING | event: " ~ github_event
                        ~ " | domain: " ~ domain_db
                        ~ " | cross domain objects: " ~ objects | length
                        ~ " | role: " ~ (grant_role if grant_role else original_role),
                        info=true
                    ) }}
                    {% set call_sql %}
                        CALL OPS_CUR.UTIL_COMMON.GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN(
                            '{{ domain_db }}',
                            '{{ json_payload | replace("'", "\'") }}')
                    {% endset %}
                    {% do run_query(call_sql) %}
                {% endfor %}

                {# Restore original session role #}
                {% if grant_role %}
                    {% do run_query('USE ROLE ' ~ original_role) %}
                {% endif %}
            {% endif %}
        {% else %}
            {% if not is_push_merge %}
                {{ log(
                    "[cross_domain_grants] SKIPPED | event: " ~ (github_event if github_event else 'unknown/local')
                    ~ " | env: " ~ target.database
                    ~ " | No cross domain models found targeting production databases."
                    ~ " In PR/PD runs, all node.database values resolve to ephemeral databases"
                    ~ " (_PR_*/_PD) and are excluded from grant processing by design.",
                    info=true
                ) }}
            {% else %}
                {{ log(
                    "[cross_domain_grants] SKIPPED | No models with CROSS_DOMAIN=TRUE found in the dbt graph."
                    ~ " Verify that cross domain models have snowflake_tags: {CROSS_DOMAIN: 'TRUE'} in their config.",
                    info=true
                ) }}
            {% endif %}
        {% endif %} {# cross_domain_by_db length check #}

        {% else %}
            {{ log(
                "[cross_domain_grants] SKIPPED | role: '" ~ target.role
                ~ "' is not a DEPLOY or ELT role — cross domain grant reconciliation only runs"
                ~ " for deployment and Airflow pipeline roles to prevent analyst runs from"
                ~ " triggering privilege changes.",
                info=true
            ) }}
        {% endif %} {# DEPLOY / ELT role guard #}

    {% endif %}
{% endmacro %}
