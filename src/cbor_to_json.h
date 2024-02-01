// Copyright (c) 2023 chessai, MIT License

#ifndef CBOR_TO_JSON_H
#define CBOR_TO_JSON_H

#include <sqlite3ext.h>

int sqlite3_cbor_to_json_create_functions(sqlite3 *db);
int sqlite3_cbortojson_init (sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);

#endif /* CBOR_TO_JSON_H */
