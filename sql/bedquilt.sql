-- # -- # -- # -- # -- #
-- Bedquilt Extension
-- # -- # -- # -- # -- #


-- # -- # -- # -- # -- #
-- Utilities
-- # -- # -- # -- # -- #


/* Generate a random string ID.
 * Used by the insert function to populate the '_id' field if missing.
 */
CREATE OR REPLACE FUNCTION bq_generate_id ()
RETURNS char(24) AS $$
BEGIN
RETURN CAST(encode(gen_random_bytes(12), 'hex') as char(24));
END
$$ LANGUAGE plpgsql;


/* private - Set a key in a json document.
 */
CREATE OR REPLACE FUNCTION bq_doc_set_key(i_jdoc json, i_key text, i_val anyelement)
RETURNS json AS $$
BEGIN
RETURN (
  SELECT concat(
      '{',
      string_agg(to_json("key")
        || ':'
        || "value", ','),
      '}'
    )::json
  FROM (SELECT *
  FROM json_each(i_jdoc)
  WHERE key <> i_key
  UNION ALL
  SELECT i_key, to_json(i_val)) as "fields")::json;
END
$$ LANGUAGE plpgsql;


/* Check if a collection exists.
 * Currently does a simple check for a table with the specified name.
 */
CREATE OR REPLACE FUNCTION bq_collection_exists (i_coll text)
RETURNS boolean AS $$
BEGIN
RETURN EXISTS (
    SELECT relname FROM pg_class WHERE relname = format('%s', i_coll)
);
END
$$ LANGUAGE plpgsql;


/* private - Ensure the _id field of the supplied json document
 * is a string value.
 * If it's not, an exception is raised. Ideally, the client should validate
 * this is the case before submitting to the server.
 */
CREATE OR REPLACE FUNCTION bq_check_id_type(i_jdoc json)
RETURNS VOID AS $$
BEGIN
  IF (SELECT json_typeof(i_jdoc->'_id')) <> 'string'
  THEN
    RAISE EXCEPTION 'The _id field is not a string: % ', i_jdoc->'_id'
    USING HINT = 'The _id field must be a string';
  END IF;
END
$$ LANGUAGE plpgsql;


-- # -- # -- # -- # -- #
-- Collection-level operations
-- # -- # -- # -- # -- #


/* Create a collection with the specified name
 */
CREATE OR REPLACE FUNCTION bq_create_collection(i_coll text)
RETURNS BOOLEAN AS $$
BEGIN
IF NOT (SELECT bq_collection_exists(i_coll))
THEN
    EXECUTE format('
    CREATE TABLE IF NOT EXISTS %1$I (
        _id varchar(256) PRIMARY KEY NOT NULL,
        bq_jdoc jsonb NOT NULL,
        created timestamptz default current_timestamp,
        updated timestamptz default current_timestamp,
        CONSTRAINT validate_id CHECK ((bq_jdoc->>''_id'') IS NOT NULL)
    );
    CREATE INDEX idx_%1$I_bq_jdoc ON %1$I USING gin (bq_jdoc);
    CREATE UNIQUE INDEX idx_%1$I_bq_jdoc_id ON %1$I ((bq_jdoc->>''_id''));
    ', i_coll);
    RETURN true;
ELSE
    RETURN false;
END IF;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


/* Get a list of existing collections.
 * This checks information_schema for tables matching the expected structure.
 */
CREATE OR REPLACE FUNCTION bq_list_collections()
RETURNS table(collection_name text) AS $$
BEGIN
RETURN QUERY SELECT table_name::text
       FROM information_schema.columns
       WHERE column_name = 'bq_jdoc'
       AND data_type = 'jsonb';
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


/* Delete/drop a collection.
 * At the moment, this just drops whatever table matches the collection name.
 */
CREATE OR REPLACE FUNCTION bq_delete_collection(i_coll text)
RETURNS BOOLEAN AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    EXECUTE format('DROP TABLE %I CASCADE;', i_coll);
    RETURN true;
ELSE
    RETURN false;
END IF;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- # -- # -- # -- # -- #
-- Document Reads
-- # -- # -- # -- # -- #


/* find one
 */
CREATE OR REPLACE FUNCTION bq_find_one(i_coll text, i_json_query json)
RETURNS table(bq_jdoc json) AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format(
        'SELECT bq_jdoc::json FROM %I
        WHERE bq_jdoc @> (%s)::jsonb
        LIMIT 1',
        i_coll,
        quote_literal(i_json_query)
    );
END IF;
END
$$ LANGUAGE plpgsql;


-- find one by id
CREATE OR REPLACE FUNCTION bq_find_one_by_id(i_coll text, i_id text)
RETURNS table(bq_jdoc json) AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format(
        'SELECT bq_jdoc::json FROM %I
        WHERE _id = %s
        LIMIT 1',
        i_coll,
        quote_literal(i_id)
    );
END IF;
END
$$ LANGUAGE plpgsql;


/* find many documents
 */
CREATE OR REPLACE FUNCTION bq_find(i_coll text, i_json_query json)
RETURNS table(bq_jdoc json) AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format(
        'SELECT bq_jdoc::json FROM %I
        WHERE bq_jdoc @> (%s)::jsonb',
        i_coll,
        quote_literal(i_json_query)
    );
END IF;
END
$$ LANGUAGE plpgsql;


/* count documents in collection
 */
CREATE OR REPLACE FUNCTION bq_count(i_coll text, i_doc json)
RETURNS integer AS $$
DECLARE
  o_value int;
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
  EXECUTE format(
    'SELECT COUNT(_id) from %I
    WHERE bq_jdoc @> (%s)::jsonb',
     i_coll,
     quote_literal(i_doc)
  ) INTO o_value;
  RETURN o_value;
ELSE
  return 0;
END IF;
END
$$ LANGUAGE plpgsql;


-- # -- # -- # -- # -- #
-- Document Writes
-- # -- # -- # -- # -- #


/* insert document
 */
CREATE OR REPLACE FUNCTION bq_insert(i_coll text, i_jdoc json)
RETURNS text AS $$
DECLARE
  doc json;
BEGIN
PERFORM bq_create_collection(i_coll);
IF (select i_jdoc->'_id') is null
THEN
  select bq_doc_set_key(i_jdoc, '_id', (select bq_generate_id())) into doc;
ELSE
  PERFORM bq_check_id_type(i_jdoc);
  doc := i_jdoc;
END IF;
EXECUTE format(
    'INSERT INTO %I (_id, bq_jdoc) VALUES (%s, %s);',
    i_coll,
    quote_literal(doc->>'_id'),
    quote_literal(doc)
);
return doc->>'_id';
END
$$ LANGUAGE plpgsql;


/* remove documents
 */
CREATE OR REPLACE FUNCTION bq_remove(i_coll text, i_jdoc json)
RETURNS setof integer AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format('
    WITH
      deleted AS
      (DELETE FROM %I WHERE bq_jdoc @> (%s)::jsonb RETURNING _id)
    SELECT count(*)::integer FROM deleted
    ', i_coll, quote_literal(i_jdoc));

ELSE
    RETURN QUERY SELECT 0;
END IF;
END
$$ LANGUAGE plpgsql;


/* remove one document
 */
CREATE OR REPLACE FUNCTION bq_remove_one(i_coll text, i_jdoc json)
RETURNS setof integer AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format('
      WITH
        candidates AS
        (SELECT _id from %1$I WHERE bq_jdoc @> (%2s)::jsonb LIMIT 1),
        deleted AS
        (DELETE FROM %1$I WHERE _id IN (select _id from candidates) RETURNING _id)
      SELECT count(*)::integer FROM deleted
    ', i_coll, quote_literal(i_jdoc));
ELSE
    RETURN QUERY SELECT 0;
END IF;
END
$$ LANGUAGE plpgsql;


/* remove one document
 */
CREATE OR REPLACE FUNCTION bq_remove_one_by_id(i_coll text, i_id text)
RETURNS setof integer AS $$
BEGIN
IF (SELECT bq_collection_exists(i_coll))
THEN
    RETURN QUERY EXECUTE format('
    WITH
    deleted AS
    (DELETE FROM %1$I WHERE _id = %2$s RETURNING _id)
    SELECT count(*)::integer FROM deleted
    ', i_coll, quote_literal(i_id));
ELSE
RETURN QUERY SELECT 0;
END IF;
END
$$ LANGUAGE plpgsql;


/* save document
 */
CREATE OR REPLACE FUNCTION bq_save(i_coll text, i_jdoc json)
RETURNS text AS $$
DECLARE
  o_id text;
  existing_id_count integer;
BEGIN
PERFORM bq_create_collection(i_coll);
IF (SELECT i_jdoc->'_id') IS NOT NULL
THEN
  EXECUTE format('select count(*) from %I where _id = %s',
                 i_coll, quote_literal(i_jdoc->>'_id'))
    INTO existing_id_count;
  IF existing_id_count > 0
    THEN
      EXECUTE format('
      UPDATE %I SET bq_jdoc = %s::jsonb WHERE _id = %s returning _id',
      i_coll,
      quote_literal(i_jdoc),
      quote_literal(i_jdoc->>'_id')) INTO o_id;
      RETURN o_id;
    ELSE
      SELECT bq_insert(i_coll, i_jdoc) INTO o_id;
      RETURN o_id;
    END IF;
ELSE
  SELECT bq_insert(i_coll, i_jdoc) INTO o_id;
  RETURN o_id;
END IF;
END
$$ LANGUAGE plpgsql;


-- # -- # -- # -- # -- #
-- Constraints
-- # -- # -- # -- # -- #


/* Add a set of constraints to the collection.
 * The supplied json document should be in the form {field: constraint_spec},
 * for example:
 *   {"age": {"$required": 1,
 *            "$notnull": 1,
 *            "$type": "number"}}
 * Valid constraints are: $required, $notnull and $type.
 * - {$required: 1} : the field must be present in all documents
 * - {$notnull: 1} : if the field is present, its value must not be null
 * - {$type: '<type>'} : if the field is present and has a non-null value,
 *       then the type of that value must match the specified type.
 *       Valid types are "string", "number", "object", "array", "boolean".
 * Returns a boolean indicating whether any of the constraints newly applied.
 */
CREATE OR REPLACE FUNCTION bq_add_constraint(i_coll text, i_jdoc json)
RETURNS boolean AS $$
DECLARE
  jdoc_keys RECORD;
  field_name text;
  spec json;
  spec_keys RECORD;
  op text;
  new_constraint_name text;
  s_type text;
  result boolean;
BEGIN
  result := false;
  -- loop over the field names
  FOR jdoc_keys in select * from json_object_keys(i_jdoc) loop
    field_name := jdoc_keys.json_object_keys;
    spec := i_jdoc->field_name;

    -- for each field name, loop over the constrant ops
    for spec_keys in select * from json_object_keys(spec) loop
      op := spec_keys.json_object_keys;
      case op
      -- $required : the key must be present in the json object
      when '$required' then
        new_constraint_name := format(
          'bqcn__%s__required',
          bq_safe_path(field_name));
        PERFORM bq_create_collection(i_coll);
        if bq_constraint_name_exists(i_coll, new_constraint_name) = false
        then
          if field_name like '%.%' then
            execute format(
              'alter table %I
              add constraint %s
              check (bq_path_exists(''%s'', bq_jdoc));',
              i_coll,
              new_constraint_name,
              field_name);
            result := true;
          else
            execute format(
              'alter table %I
              add constraint %s
              check (bq_jdoc ? ''%s'');',
              i_coll,
              new_constraint_name,
              field_name);
            result := true;
          end if;
        end if;
      -- $notnull : the key must be present in the json object
      when '$notnull' then
        new_constraint_name := format(
          'bqcn__%s__notnull',
          bq_safe_path(field_name));
        PERFORM bq_create_collection(i_coll);
        if bq_constraint_name_exists(i_coll, new_constraint_name) = false
        then
          execute format(
            'alter table %I
            add constraint %s
            check (
              jsonb_typeof((bq_jdoc#>''%s'')::jsonb) <> ''null''
            );',
            i_coll,
            new_constraint_name,
            regexp_split_to_array(field_name, '\.'));
          result := true;
        end if;
      -- $type: enforce type of the specified field
      --   valid values are:
      --   'string' | 'number' | 'object' | 'array' | 'boolean'
      when '$type' then
        s_type := spec->>op;
        new_constraint_name := format(
          'bqcn__%s__type__%s',
          bq_safe_path(field_name), s_type);
        PERFORM bq_create_collection(i_coll);
        if bq_constraint_name_exists(i_coll, new_constraint_name) = false
        then
          if s_type not in ('string','object','array','boolean','number')
          then
            raise exception
            'Invalid $type ("%") specified for field "%"',
            s_type, field_name
            using hint = 'Please specify the name of a json type';
          end if;
          -- check if we've got a type constraint already
          if exists(
            select constraint_name
            from information_schema.constraint_column_usage
            where table_name = i_coll
            and constraint_name like 'bqcn__'
            || bq_safe_path(field_name)
            ||'__type__%')
          then
            raise exception
            'Contradictory $type "%" constraint on field "%"',
            s_type, field_name
            using hint = 'Please remove existing $type constraint';
          end if;
          execute format(
            'alter table %I
            add constraint %s
            check (
              jsonb_typeof(bq_jdoc#>''%s'') in (''%s'', ''null'')
            );',
            i_coll,
            new_constraint_name,
            regexp_split_to_array(field_name, '\.'),
            s_type);
          result := true;
        end if;
      end case;

    end loop;

  end loop;

  RETURN result;
END
$$ LANGUAGE plpgsql;


/* private - replace dots in path string with underscores
 */
CREATE OR REPLACE FUNCTION bq_safe_path(i_path text)
RETURNS text AS $$
BEGIN
  RETURN replace(i_path, '.', '_');
END
$$ LANGUAGE plpgsql;


/* private - check if a constraint name exists
 */
CREATE OR REPLACE FUNCTION bq_constraint_name_exists(i_coll text, i_name text)
RETURNS boolean AS $$
BEGIN
  return exists(
    select * from information_schema.constraint_column_usage
    where table_name = i_coll
    and constraint_name = i_name
  );
END
$$ LANGUAGE plpgsql;


/* Remove constraints from collection.
 * The supplied json document should match the spec for existing constraints.
 * Returns True if any of the constraints were removed, False otherwise.
 */
CREATE OR REPLACE FUNCTION bq_remove_constraint(i_coll text, i_jdoc json)
RETURNS boolean AS $$
DECLARE
  jdoc_keys RECORD;
  field_name text;
  spec json;
  spec_keys RECORD;
  op text;
  target_constraint text;
  s_type text;
  result boolean;
BEGIN

  result := false;
  -- loop over the field names
  FOR jdoc_keys in select * from json_object_keys(i_jdoc) loop
    field_name := jdoc_keys.json_object_keys;
    spec := i_jdoc->field_name;

    -- for each field name, loop over the constrant ops
    for spec_keys in select * from json_object_keys(spec) loop
      op := spec_keys.json_object_keys;
      case op
      when '$required' then
        target_constraint := format(
          'bqcn__%s__required',
          field_name);
        if bq_constraint_name_exists(i_coll, target_constraint)
        then
          execute format(
            'alter table %I
            drop constraint %s;',
            i_coll,
            target_constraint
          );
          result := true;
        end if;

      when '$notnull' then
        target_constraint := format(
          'bqcn__%s__notnull',
          field_name);
        if bq_constraint_name_exists(i_coll, target_constraint)
        then
          execute format(
            'alter table %I
            drop constraint %s;',
            i_coll,
            target_constraint
          );
          result := true;
        end if;

      when '$type' then
        s_type := spec->>op;
        target_constraint := format(
          'bqcn__%s__type__%s',
          field_name, s_type);
        if bq_constraint_name_exists(i_coll, target_constraint)
        then
          execute format(
            'alter table %I
            drop constraint %s;',
            i_coll,
            target_constraint
          );
          result := true;
        end if;
      end case;

    end loop;
  end loop;

  return result;
END
$$ LANGUAGE plpgsql;


/* Get a list of text descriptions of constraints on this collection.
 */
CREATE OR REPLACE FUNCTION bq_list_constraints(i_coll text)
RETURNS setof text AS $$
BEGIN
return query select
  replace(substring(constraint_name from 7), '__', ':' )
  from information_schema.constraint_column_usage
  where table_name = i_coll
  and constraint_name like 'bqcn_%';
END
$$ LANGUAGE plpgsql;


/* private - Check if a dotted path exists in a document
 */
create or replace function bq_path_exists(i_path text, i_jdoc jsonb)
returns boolean as $$
DECLARE
  path_array text[];
  depth int;
  path_key text;
  current_object jsonb;
BEGIN
  current_object := i_jdoc;
  if i_path = '' then
    return false;
  end if;
  if i_path not like '%.%' then
    return (current_object ? i_path);
  end if;

  path_array := regexp_split_to_array(i_path, '\.');
  foreach path_key in array path_array loop
    if jsonb_typeof(current_object) = 'object' then
      if current_object ? path_key then
        current_object := current_object->path_key;
      else
        return false;
      end if;
    elsif jsonb_typeof(current_object) = 'array' then
      if path_key ~ '^\d+$' then
        current_object := current_object->path_key::int;
      else
        return false;
      end if;
    else
      return false;
    end if;
  end loop;
  return true;

END
$$ language plpgsql;
