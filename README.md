# DBT Standard Package
DBT (Data Build Tool) is a popular open-source tool for transforming and modeling data in modern data warehouses. It allows you to build and maintain a data transformation pipeline that is reliable, maintainable, and testable. One of the key features of DBT is the ability to package your models and macros into reusable DBT packages.

A DBT package is a collection of DBT models and macros that are organized into a single package, making it easy for other teams to use and reuse the models and macros across multiple projects.

One of the advantages of using DBT packages is that it promotes code reuse and standardization. With packages, you can define common models and macros that can be used across multiple projects, ensuring consistency and reducing the risk of errors.

To put common models and macros into a DBT package, you need to organize your code into a directory structure that conforms to the DBT package specification. This includes defining the package.yml file, which specifies the name and version of the package, as well as the models and macros that are included.

DBT also provides a way to import DBT packages into your project. You can do this by adding the package name and version to your project's packages.yml file. When you run the dbt deps command, DBT will download and install the required packages from the package repository.

You can even import one DBT package into another DBT package. This is useful when you have a set of models or macros that are used across multiple packages. To do this, you simply include the package name and version in the depends_on section of the package.yml file.

Overall, DBT packages provide a powerful way to organize and reuse your DBT models and macros. By packaging your code into reusable components, you can improve code quality, reduce development time, and promote consistency across your data transformation pipeline.


## Quickstart

Here is a quick start guide for creating a custom dbt standard package  (`cp-dbt-standard-package`) by importing `brooklyn-data/dbt_artifacts` (https://github.com/brooklyn-data/dbt_artifacts) and adding two new macros, `drop_unneeded_objects.sql` and `get_custom_schema.sql`.


1. Create `packages.yml` file and import this package to the `packages.yml`:
```
packages:
  - package: brooklyn-data/dbt_artifacts
    version: 2.3.0
```

2. Add an on-run-end hook to the `dbt_project.yml`: `on-run-end: "{{ dbt_artifacts.upload_results(results) if (env_var('DBT_ARTIFACTS_DATABASE', 'not-set') != 'not-set' )}}"`


3. Create a new file called `drop_unneeded_objects.sql` inside the `macros` directory - The drop_unneeded_objects.sql macro is a custom macro in dbt that can be used to drop tables or views that are no longer needed in a database.


4. Create a new file called `get_custom_schema.sql` inside the `macros` directory - The get_custom_schema.sql macro is a custom macro that can be used in a dbt project to obtain the name of a custom schema. It can be useful when the name of the schema varies depending on the environment, configuration, or other factors.


# Note

We need to set the `DBT_ARTIFACTS_DATABASE` and  `DBT_ARTIFACTS_SCHEMA` environment variable to the name of a database where you have write permissions. When this variable is set, dbt will use the database and schema to store all artifacts.
Dbt artifacts are the output of dbt runs, such as compiled SQL queries, dbt run, dbt snapshots, dbt seed etc.