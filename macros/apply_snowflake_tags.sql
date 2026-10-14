{#
  Snowflake Tagging Package ('dbt_snowflake_tagging')
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
        {{ return('') }}
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
            {{ return('') }}
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

    {# Iceberg tables require ALTER ICEBERG TABLE; views must not use ICEBERG prefix #}
    {% set ddl_prefix = 'ICEBERG ' if is_iceberg and relation_type == 'TABLE' else '' %}
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
        {{ return('') }}
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
            {{ return('') }}
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

    {# Iceberg tables require ALTER ICEBERG TABLE; views must not use ICEBERG prefix #}
    {% set ddl_prefix = 'ICEBERG ' if is_iceberg and relation_type == 'TABLE' else '' %}
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
                   A model is Iceberg if table_format='iceberg' or catalog_name is set.
                   Views use ALTER VIEW DDL (never ALTER ICEBERG VIEW). #}
                {% set catalog_nm = node.config.get('catalog_name') %}
                {% set model_is_iceberg = (node.config.get('table_format', '') == 'iceberg')
                    or (catalog_nm is not none and catalog_nm | string | length > 0) %}
                {% if rel_type == 'VIEW' %}
                    {% set model_is_iceberg = false %}
                {% endif %}

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
   Called automatically by on-run-end hook to reapply tags after dbt runs.

   DPB-2513 guards, in order:
     1. Command guard: skip when the current dbt invocation cannot have
        created or replaced Snowflake objects (test / compile / parse /
        deps / list / docs / debug / show / clean / init / source ...).
        Belt-and-suspenders with the yaml-level guard in dbt_project.yml —
        protects any downstream project that wires this macro into
        on-run-end without the yaml guard, and covers `dbt source freshness`
        (which runs on-run-end hooks by default as of dbt-core 1.10; the
        `source_freshness_run_project_hooks` flag was removed in v2.0).
     2. Metadata-package guard: skip when the only successful models were
        from `dbt_project_evaluator`. dbt-common CI runs that package as its
        own dedicated `dbt build --select package:dbt_project_evaluator+`
        step; its models never carry `snowflake_tags`, so there is nothing
        to reapply. Extend the ignore list if new metadata-only packages
        (e.g. elementary) are added to CI.
   ============================================================ #}
{% macro tag_models_from_results() %}
    {% if execute %}
        {% set object_mutating_cmds = ['run', 'build', 'seed', 'snapshot', 'clone'] %}
        {% if flags.WHICH not in object_mutating_cmds %}
            {{ log(
                "[tag_models_from_results] SKIPPED | command '" ~ flags.WHICH
                ~ "' does not create or replace Snowflake objects — nothing to tag."
                ~ " Hook only fires for: " ~ object_mutating_cmds | join(', '),
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {% set ignore_packages = ['dbt_project_evaluator'] %}
        {% set successful_models = [] %}
        {% for res in results %}
            {% if res.node.resource_type == 'model'
              and res.status in ['success', 'pass']
              and res.node.package_name not in ignore_packages %}
                {% do successful_models.append(res.node.unique_id) %}
            {% endif %}
        {% endfor %}

        {% if successful_models | length > 0 %}
            {{ log("Auto-tagging " ~ successful_models | length ~ " deployed model(s)", info=true) }}
            {{ cp_dbt_standard_package.tag_models_on_run_end(successful_models) }}
        {% else %}
            {{ log(
                "[tag_models_from_results] SKIPPED | no user-project models successfully built"
                ~ " (ignoring packages: " ~ ignore_packages | join(', ') ~ ") — nothing to tag.",
                info=true
            ) }}
        {% endif %}
    {% endif %}
{% endmacro %}


{# ============================================================
   CALL CERTIFIED READ PROCEDURE (on-run-end)

   Zero-latency alternative to the hourly GRANT_CERTIFIED_READ_ACCESS /
   TAG_BASED_RBAC_CERT_PROC task. Walks the dbt graph, builds a JSON
   manifest of IS_CERTIFIED objects, and CALLs
   GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN once per domain database.

   Twin of call_cross_domain_read_proc (same flow; different tag/proc).
   Keep both while teams move from CERTIFIED_READ → CROSS_DOMAIN.

   DPSA-620: removed the old GITHUB_EVENT dry-run (push/merge = CALL,
   else log-only). Airflow has no GitHub event, so ELT never CALLed and
   morning rebuilds left CERTIFIED_READ broken until the hourly task.
   Snowflake DEV and PROD both use real {DOMAIN}_CUR / {DOMAIN}_CON
   (DPI AGENTS.md). Only CI _PR_* / *_PD are ephemeral — skip those,
   otherwise CALL. No dry-run path.

   Primary gates live in dbt_project.yml; guards below cover projects
   that wire this macro without those yaml checks.

   ELT: proc is EXECUTE AS OWNER, so ELT only needs EXECUTE.
   get_tagging_role only flips *_DEPLOY_CUR ↔ *_DEPLOY_CON; ELT unchanged.
   ============================================================ #}
{% macro call_certified_read_proc() %}
    {% if execute %}

        {% set object_mutating_cmds = ['run', 'build', 'seed', 'snapshot', 'clone'] %}
        {% if flags.WHICH not in object_mutating_cmds %}
            {{ log(
                "[certified_read_grants] SKIPPED | command '" ~ flags.WHICH
                ~ "' — nothing rebuilt",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {% set ignore_packages = ['dbt_project_evaluator'] %}
        {% set grantable_resource_types = ('model', 'seed', 'snapshot') %}
        {% set grantable_nodes = [] %}
        {% for res in results %}
            {% if res.node.resource_type in grantable_resource_types
              and res.status in ['success', 'pass']
              and res.node.package_name not in ignore_packages %}
                {% do grantable_nodes.append(res.node.unique_id) %}
            {% endif %}
        {% endfor %}
        {% if grantable_nodes | length == 0 %}
            {{ log(
                "[certified_read_grants] SKIPPED | no models/seeds/snapshots built"
                ~ " (ignoring " ~ ignore_packages | join(', ') ~ ")",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {% set db_upper = target.database | upper %}
        {% if '_PR_' in db_upper or db_upper.endswith('_PD') %}
            {{ log(
                "[certified_read_grants] SKIPPED | ephemeral db '" ~ target.database
                ~ "' — no grants from PR/PD",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# DEPLOY (CI) and ELT (Airflow) both rebuild models and wipe grants #}
        {% set role_upper = target.role | upper %}
        {% if 'DEPLOY' not in role_upper and 'ELT' not in role_upper %}
            {{ log(
                "[certified_read_grants] SKIPPED | role '" ~ target.role
                ~ "' is not DEPLOY or ELT",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# DPB-2838: only CALL if this run rebuilt certified CON models.
           WHETHER to CALL is this-run; WHAT to send is the full graph below. #}
        {% if cp_dbt_standard_package.get_certified_consumption_objects() | length == 0 %}
            {{ log(
                "[certified_read_grants] SKIPPED | no certified CON models rebuilt this run",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# --------------------------------------------------------
           Step 1: walk the full graph for every IS_CERTIFIED model,
           grouped by resolved target database. Include siblings not
           rebuilt this run so BY_DOMAIN reconcile stays complete.
           Resolve tags from config.snowflake_tags or meta.snowflake_tags.
           -------------------------------------------------------- #}
        {% set certified_read_by_db = {} %}
        {% set skipped_ephemeral = [] %}
        {% for node_id, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {% set model_tags  = node.config.get('snowflake_tags', {}) %}
                {% set meta_tags   = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                {% set certified_read = false %}
                {% if model_tags.get('IS_CERTIFIED', '') | upper == 'TRUE' %}
                    {% set certified_read = true %}
                {% elif meta_tags.get('IS_CERTIFIED', '') | upper == 'TRUE' %}
                    {% set certified_read = true %}
                {% endif %}
                {% if certified_read %}
                    {% set mat = node.config.materialized %}
                    {# Ephemeral models produce no physical relation. Sending
                       them into the by-domain proc fails with 002003 on
                       GRANT SELECT. Collect names for a roll-up log below. #}
                    {% if mat == 'ephemeral' %}
                        {% do skipped_ephemeral.append(node.name) %}
                    {% else %}
                        {% set db = node.database | upper %}
                        {# Normalize ephemeral env suffixes back to prod DB.
                           Split from the LEFT — db.split('_PR_')[0] yields ''
                           for names like _PR_67_FIN_CON (they start with _PR_).
                             _PR_{N}_{DOMAIN}_{LAYER} -> parts[3:] = DOMAIN_LAYER
                             {DOMAIN}_{LAYER}_PD      -> strip trailing _PD
                             {DOMAIN}_{LAYER}         -> unchanged #}
                        {% if db.startswith('_PR_') %}
                            {% set parts = db.split('_') %}
                            {% set db = parts[3:] | join('_') %}
                        {% elif db.endswith('_PD') %}
                            {% set db = db[:-3] %}
                        {% endif %}
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
            {% endif %}
        {% endfor %}

        {% if skipped_ephemeral | length > 0 %}
            {{ log(
                "[certified_read_grants] skipped " ~ skipped_ephemeral | length
                ~ " ephemeral IS_CERTIFIED model(s): " ~ skipped_ephemeral | join(', ')
                ~ " — no physical relation; omitted from grant manifest.",
                info=true
            ) }}
        {% endif %}

        {% if certified_read_by_db | length == 0 %}
            {{ log(
                "[certified_read_grants] SKIPPED | no IS_CERTIFIED models in graph",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# --------------------------------------------------------
           Step 2: CALL GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN once per
           domain with the scoped JSON manifest.

           Role switch: grant proc should run as {domain}_DEPLOY_CON when
           the session is DEPLOY_CUR (and the reverse). Switch once for
           the loop and always restore afterwards. get_tagging_role uses
           target.database to infer CUR vs CON. ELT roles are left as-is
           (proc runs EXECUTE AS OWNER).
           -------------------------------------------------------- #}
        {% set original_role = target.role | upper %}
        {% set grant_role = cp_dbt_standard_package.get_tagging_role(target.database) %}
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
                "[certified_read_grants] CALLING | env: " ~ target.database
                ~ " | domain: " ~ domain_db
                ~ " | certified read objects: " ~ objects | length
                ~ " | role: " ~ (grant_role if grant_role else original_role),
                info=true
            ) }}
            {# Snowflake single-quoted string escape is a doubled apostrophe
               (''), not a backslash. A prior `\'` escape left a raw ' inside
               the literal and broke payloads with apostrophes in names. #}
            {% set call_sql %}
                CALL OPS_CUR.UTIL_COMMON.GRANT_CERTIFIED_READ_ACCESS_BY_DOMAIN(
                    '{{ domain_db }}',
                    '{{ json_payload | replace("'", "''") }}')
            {% endset %}
            {% do run_query(call_sql) %}
        {% endfor %}

        {% if grant_role %}
            {% do run_query('USE ROLE ' ~ original_role) %}
        {% endif %}

    {% endif %}
{% endmacro %}

{# ============================================================
   GET CERTIFIED CONSUMPTION OBJECTS (DPB-2838)

   Successful models from this run's results that are consumption-layer
   (_CON / _CON_PD / _PR_*_*_CON) and tagged IS_CERTIFIED=TRUE.
   Used by dbt_project.yml not-entered gates and by call_certified_read_proc.
   Tags: config.snowflake_tags, then config.meta.snowflake_tags.
   ============================================================ #}
{% macro get_certified_consumption_objects() %}
    {% set certified = [] %}
    {% if execute %}
        {% for res in results %}
            {% set node = res.node %}
            {% if node.resource_type == 'model' and res.status in ['success', 'pass'] %}
                {% set db = node.database | default('', true) | upper %}
                {% set db_root = db[:-3] if db.endswith('_PD') else db %}
                {% if db_root.endswith('_CON') or (db.startswith('_PR_') and db.endswith('_CON')) %}
                    {% set model_tags = node.config.get('snowflake_tags', {}) %}
                    {% set meta_tags = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                    {% if (model_tags.get('IS_CERTIFIED', '') | string | trim | upper) == 'TRUE'
                      or (meta_tags.get('IS_CERTIFIED', '') | string | trim | upper) == 'TRUE' %}
                        {% do certified.append(node.unique_id) %}
                    {% endif %}
                {% endif %}
            {% endif %}
        {% endfor %}
    {% endif %}
    {{ return(certified) }}
{% endmacro %}


{# ============================================================
   GET CROSS DOMAIN OBJECTS THIS RUN (DPB-2838)

   Same shape as get_certified_consumption_objects, but for
   CROSS_DOMAIN=TRUE on successful consumption-layer models.
   ============================================================ #}
{% macro get_cross_domain_objects_this_run() %}
    {% set cross_domain_objs = [] %}
    {% if execute %}
        {% for res in results %}
            {% set node = res.node %}
            {% if node.resource_type == 'model' and res.status in ['success', 'pass'] %}
                {% set db = node.database | default('', true) | upper %}
                {% set db_root = db[:-3] if db.endswith('_PD') else db %}
                {% if db_root.endswith('_CON') or (db.startswith('_PR_') and db.endswith('_CON')) %}
                    {% set model_tags = node.config.get('snowflake_tags', {}) %}
                    {% set meta_tags = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                    {% if (model_tags.get('CROSS_DOMAIN', '') | string | trim | upper) == 'TRUE'
                      or (meta_tags.get('CROSS_DOMAIN', '') | string | trim | upper) == 'TRUE' %}
                        {% do cross_domain_objs.append(node.unique_id) %}
                    {% endif %}
                {% endif %}
            {% endif %}
        {% endfor %}
    {% endif %}
    {{ return(cross_domain_objs) }}
{% endmacro %}


{# ============================================================
   CALL CROSS_DOMAIN READ PROCEDURE (on-run-end)

   Zero-latency alternative to the hourly GRANT_CROSS_DOMAIN_READ_ACCESS /
   TAG_BASED_RBAC_CROSS_DOMAIN_PROC task. Same flow as
   call_certified_read_proc: graph walk → CALL
   GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN once per domain.

   Keep in lockstep with the certified macro (DPSA-620: no GITHUB_EVENT
   dry-run; skip _PR_* / *_PD; otherwise CALL on real DEV/PROD DBs).
   ============================================================ #}
{% macro call_cross_domain_read_proc() %}
    {% if execute %}

        {% set object_mutating_cmds = ['run', 'build', 'seed', 'snapshot', 'clone'] %}
        {% if flags.WHICH not in object_mutating_cmds %}
            {{ log(
                "[cross_domain_grants] SKIPPED | command '" ~ flags.WHICH
                ~ "' — nothing rebuilt",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {% set ignore_packages = ['dbt_project_evaluator'] %}
        {% set grantable_resource_types = ('model', 'seed', 'snapshot') %}
        {% set grantable_nodes = [] %}
        {% for res in results %}
            {% if res.node.resource_type in grantable_resource_types
              and res.status in ['success', 'pass']
              and res.node.package_name not in ignore_packages %}
                {% do grantable_nodes.append(res.node.unique_id) %}
            {% endif %}
        {% endfor %}
        {% if grantable_nodes | length == 0 %}
            {{ log(
                "[cross_domain_grants] SKIPPED | no models/seeds/snapshots built"
                ~ " (ignoring " ~ ignore_packages | join(', ') ~ ")",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {% set db_upper = target.database | upper %}
        {% if '_PR_' in db_upper or db_upper.endswith('_PD') %}
            {{ log(
                "[cross_domain_grants] SKIPPED | ephemeral db '" ~ target.database
                ~ "' — no grants from PR/PD",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# DEPLOY (CI) and ELT (Airflow) both rebuild models and wipe grants #}
        {% set role_upper = target.role | upper %}
        {% if 'DEPLOY' not in role_upper and 'ELT' not in role_upper %}
            {{ log(
                "[cross_domain_grants] SKIPPED | role '" ~ target.role
                ~ "' is not DEPLOY or ELT",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# DPB-2838: WHETHER to CALL is this-run; WHAT to send is full graph #}
        {% if cp_dbt_standard_package.get_cross_domain_objects_this_run() | length == 0 %}
            {{ log(
                "[cross_domain_grants] SKIPPED | no CROSS_DOMAIN CON models rebuilt this run",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# --------------------------------------------------------
           Step 1: walk the full graph for every CROSS_DOMAIN model,
           grouped by resolved target database (siblings included).
           -------------------------------------------------------- #}
        {% set cross_domain_by_db = {} %}
        {% set skipped_ephemeral = [] %}
        {% for node_id, node in graph.nodes.items() %}
            {% if node.resource_type == 'model' %}
                {% set model_tags  = node.config.get('snowflake_tags', {}) %}
                {% set meta_tags   = node.config.get('meta', {}).get('snowflake_tags', {}) %}
                {% set cross_domain = false %}
                {% if model_tags.get('CROSS_DOMAIN', '') | upper == 'TRUE' %}
                    {% set cross_domain = true %}
                {% elif meta_tags.get('CROSS_DOMAIN', '') | upper == 'TRUE' %}
                    {% set cross_domain = true %}
                {% endif %}
                {% if cross_domain %}
                    {% set mat = node.config.materialized %}
                    {# Ephemeral models produce no physical relation. Sending
                       them into the by-domain proc fails with 002003 on
                       GRANT SELECT. Collect names for a roll-up log below. #}
                    {% if mat == 'ephemeral' %}
                        {% do skipped_ephemeral.append(node.name) %}
                    {% else %}
                        {% set db = node.database | upper %}
                        {# Normalize ephemeral env suffixes back to prod DB.
                           Split from the LEFT — db.split('_PR_')[0] yields ''
                           for names like _PR_67_FIN_CON (they start with _PR_).
                             _PR_{N}_{DOMAIN}_{LAYER} -> parts[3:] = DOMAIN_LAYER
                             {DOMAIN}_{LAYER}_PD      -> strip trailing _PD
                             {DOMAIN}_{LAYER}         -> unchanged #}
                        {% if db.startswith('_PR_') %}
                            {% set parts = db.split('_') %}
                            {% set db = parts[3:] | join('_') %}
                        {% elif db.endswith('_PD') %}
                            {% set db = db[:-3] %}
                        {% endif %}
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
            {% endif %}
        {% endfor %}

        {% if skipped_ephemeral | length > 0 %}
            {{ log(
                "[cross_domain_grants] skipped " ~ skipped_ephemeral | length
                ~ " ephemeral CROSS_DOMAIN model(s): " ~ skipped_ephemeral | join(', ')
                ~ " — no physical relation; omitted from grant manifest.",
                info=true
            ) }}
        {% endif %}

        {% if cross_domain_by_db | length == 0 %}
            {{ log(
                "[cross_domain_grants] SKIPPED | no CROSS_DOMAIN models in graph",
                info=true
            ) }}
            {{ return('') }}
        {% endif %}

        {# --------------------------------------------------------
           Step 2: CALL GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN once
           per domain. Same DEPLOY CUR/CON role switch as certified;
           ELT left as-is (EXECUTE AS OWNER on the proc).
           -------------------------------------------------------- #}
        {% set original_role = target.role | upper %}
        {% set grant_role = cp_dbt_standard_package.get_tagging_role(target.database) %}
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
                "[cross_domain_grants] CALLING | env: " ~ target.database
                ~ " | domain: " ~ domain_db
                ~ " | cross domain objects: " ~ objects | length
                ~ " | role: " ~ (grant_role if grant_role else original_role),
                info=true
            ) }}
            {# Snowflake single-quoted string escape is a doubled apostrophe
               (''), not a backslash. A prior `\'` escape left a raw ' inside
               the literal and broke payloads with apostrophes in names. #}
            {% set call_sql %}
                CALL OPS_CUR.UTIL_COMMON.GRANT_CROSS_DOMAIN_READ_ACCESS_BY_DOMAIN(
                    '{{ domain_db }}',
                    '{{ json_payload | replace("'", "''") }}')
            {% endset %}
            {% do run_query(call_sql) %}
        {% endfor %}

        {% if grant_role %}
            {% do run_query('USE ROLE ' ~ original_role) %}
        {% endif %}

    {% endif %}
{% endmacro %}
