/*
 * Copyright (c) 2023 chessai <chessai1996@gmail.com>
 *
 * Parts of this code are adapted from the examples in libcbor;
 * Copyright (c) 2014-2020 Pavel Kalvoda <me@pavelkalvoda.com>
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#include <assert.h>
#include <string.h>
#include <stdarg.h>

#ifndef SQLITE_AMALGAMATION
typedef sqlite3_uint64 u64;
#endif /* SQLITE_AMALGAMATION */

#include <cjson/cJSON.h>
#include <cbor.h>

#include <stdio.h>
#include <string.h>

#include "cbor_to_json.h"

// Portable unused argument hack to pass -Wall -Wextra -Werror
#define UNUSED(arg) (void)(arg)

char* to_hex_string(const unsigned char *str, size_t length)
{
    char *outstr = malloc(2 + 2*length + 1);
    if (!outstr) return outstr;

    char *p = outstr;
    p += sprintf(p, "0x");
    for (size_t i = 0; i < length; i++) {
        p += sprintf(p, "%x", str[i]);
    }

    return outstr;
}

cJSON* cbor_to_cjson(const cbor_item_t* item, const bool keep_tags) {
  switch (cbor_typeof(item)) {
    case CBOR_TYPE_UINT:
      return cJSON_CreateNumber(cbor_get_int(item));
    case CBOR_TYPE_NEGINT:
      // see https://github.com/PJK/libcbor/issues/56 for an explanation
      // of why this calculates the negative integer this way
      return cJSON_CreateNumber((-1 * ((int64_t)cbor_get_int(item))) - 1);
    case CBOR_TYPE_BYTESTRING:
      // cJSON only handles null-terminated strings -- binary data would have to
      // be escaped. we make the (somewhat arbitrary) choice here of
      // hex-encoding the byte string.
      uint8_t *output;
      size_t output_size;
      size_t allocated = cbor_serialize_alloc(item, &output, &output_size);

      char *hex = to_hex_string(output, allocated);
      return cJSON_CreateString(hex);
    case CBOR_TYPE_STRING:
      if (cbor_string_is_definite(item)) {
        // cJSON only handles null-terminated string
        char* null_terminated_string = malloc(cbor_string_length(item) + 1);
        memcpy(null_terminated_string, cbor_string_handle(item),
               cbor_string_length(item));
        null_terminated_string[cbor_string_length(item)] = 0;
        cJSON* result = cJSON_CreateString(null_terminated_string);
        free(null_terminated_string);
        return result;
      }
      return cJSON_CreateString("Unsupported CBOR item: Chunked string");
    case CBOR_TYPE_ARRAY: {
      cJSON* result = cJSON_CreateArray();
      for (size_t i = 0; i < cbor_array_size(item); i++) {
        cJSON_AddItemToArray(result, cbor_to_cjson(cbor_array_get(item, i), keep_tags));
      }
      return result;
    }
    case CBOR_TYPE_MAP: {
      cJSON* result = cJSON_CreateObject();
      for (size_t i = 0; i < cbor_map_size(item); i++) {
        char* key = malloc(128);
        snprintf(key, 128, "Surrogate key %zu", i);
        // JSON only support string keys
        if (cbor_isa_string(cbor_map_handle(item)[i].key) &&
            cbor_string_is_definite(cbor_map_handle(item)[i].key)) {
          size_t key_length = cbor_string_length(cbor_map_handle(item)[i].key);
          if (key_length > 127) key_length = 127;
          // Null-terminated madness
          memcpy(key, cbor_string_handle(cbor_map_handle(item)[i].key),
                 key_length);
          key[key_length] = 0;
        }

        cJSON_AddItemToObject(result, key,
                              cbor_to_cjson(cbor_map_handle(item)[i].value, keep_tags));
        free(key);
      }
      return result;
    }
    case CBOR_TYPE_TAG:
      // If keep_tags, create an object with keys "tag" and "item".
      // Otherwise, just return the tagged item.
      if (keep_tags) {
        cJSON* result = cJSON_CreateObject();
        uint64_t tag_value = cbor_tag_value(item);
        cbor_item_t *tagged_item = cbor_tag_item(item);

        cJSON_AddItemToObject(result, "tag", cJSON_CreateNumber(tag_value));
        cJSON_AddItemToObject(result, "item", cbor_to_cjson(tagged_item, keep_tags));

        return result;
      } else {
          return cbor_to_cjson(item, keep_tags);
      }
    case CBOR_TYPE_FLOAT_CTRL:
      if (cbor_float_ctrl_is_ctrl(item)) {
        if (cbor_is_bool(item)) return cJSON_CreateBool(cbor_get_bool(item));
        if (cbor_is_null(item)) return cJSON_CreateNull();
        return cJSON_CreateString("Unsupported CBOR item: Control value");
      }
      return cJSON_CreateNumber(cbor_float_get_float(item));
  }

  return cJSON_CreateNull();
}

char* encode_cbor_error(struct cbor_error err) {
  const int prefix_len = 9;
  char* msg;

  switch(err.code) {
    case CBOR_ERR_NOTENOUGHDATA:
        msg = malloc(prefix_len + 13 + 1);
        sprintf(msg, "CBOR_ERR_NOTENOUGHDATA");
        return msg;
    case CBOR_ERR_NODATA:
        msg = malloc(prefix_len + 6 + 1);
        sprintf(msg, "CBOR_ERR_NODATA");
        return msg;
    case CBOR_ERR_MALFORMATED:
        msg = malloc(prefix_len + 11 + 1);
        sprintf(msg, "CBOR_ERR_MALFORMATED");
        return msg;
    case CBOR_ERR_MEMERROR:
        msg = malloc(prefix_len + 8 + 1);
        sprintf(msg, "CBOR_ERR_MEMERROR");
        return msg;
    case CBOR_ERR_SYNTAXERROR:
        msg = malloc(prefix_len + 11 + 1);
        sprintf(msg, "CBOR_ERR_NODATA");
        return msg;
    default:
        return NULL;
  }
}

static void cbor_to_json(const bool keep_tags, sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
  assert(argc == 1);

  sqlite3_value* cbor = argv[0];
  int value_bytes = sqlite3_value_bytes(cbor);

  struct cbor_load_result result;
  cbor_item_t* item = cbor_load(sqlite3_value_blob(cbor), value_bytes, &result);

  if (result.error.code != CBOR_ERR_NONE) {
    char* err_msg = encode_cbor_error(result.error);
    if (err_msg != NULL) {
      sqlite3_result_error(ctx, err_msg, -1);
      free(err_msg);
    } else {
      sqlite3_result_error(ctx, "Failed to decode CBOR", -1);
    }
  }

  cJSON* cjson_item = cbor_to_cjson(item, keep_tags);
  char* json_string = cJSON_PrintUnformatted(cjson_item);

  // Deallocate cbor stuff
  cbor_decref(&item);
  cJSON_Delete(cjson_item);

  sqlite3_result_text64(ctx, json_string, strlen(json_string), SQLITE_TRANSIENT, SQLITE_UTF8);
}

static void cbor_to_json_untagged(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    return cbor_to_json(false, ctx, argc, argv);
}

static void cbor_to_json_tagged(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    return cbor_to_json(true, ctx, argc, argv);
}

/* ************************************************************************** */
/* Initialize functions
 */
int sqlite3_cbor_to_json_create_functions(sqlite3 *db)
{
  int rc = SQLITE_OK;
  const int rep = SQLITE_UTF8 | SQLITE_INNOCUOUS | SQLITE_DETERMINISTIC;

  if (rc == SQLITE_OK) {
    rc = sqlite3_create_function(db, "cbor_to_json", -1, rep, 0, cbor_to_json_untagged, 0, 0);
  }

  if (rc == SQLITE_OK) {
    rc = sqlite3_create_function(db, "cbor_to_json_tagged", -1, rep, 0, cbor_to_json_tagged, 0, 0);
  }

  return rc;
}

/* ************************************************************************** */
/* SQLite Extension
 *
 * When compiled as shared library this supports dynamic loading of the
 * extension.
 */
int sqlite3_cbortojson_init (
    sqlite3 *db,
    char **pzErrMsg,
    const sqlite3_api_routines *pApi
) {
  UNUSED(pzErrMsg);
  SQLITE_EXTENSION_INIT2(pApi);
  sqlite3_cbor_to_json_create_functions(db);
  return SQLITE_OK;
}
