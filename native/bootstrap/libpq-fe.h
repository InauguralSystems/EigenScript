#ifndef LIBPQ_FE_H
#define LIBPQ_FE_H

typedef struct pg_conn PGconn;
typedef struct pg_result PGresult;

typedef enum { CONNECTION_OK, CONNECTION_BAD } ConnStatusType;
typedef enum { PGRES_EMPTY_QUERY, PGRES_COMMAND_OK, PGRES_TUPLES_OK, PGRES_COPY_OUT,
               PGRES_COPY_IN, PGRES_BAD_RESPONSE, PGRES_NONFATAL_ERROR, PGRES_FATAL_ERROR } ExecStatusType;

extern PGconn *PQconnectdb(const char *conninfo);
extern void PQfinish(PGconn *conn);
extern ConnStatusType PQstatus(const PGconn *conn);
extern char *PQerrorMessage(const PGconn *conn);
extern PGresult *PQexec(PGconn *conn, const char *query);
extern PGresult *PQexecParams(PGconn *conn, const char *command, int nParams,
    const void *paramTypes, const char *const *paramValues,
    const int *paramLengths, const int *paramFormats, int resultFormat);
extern ExecStatusType PQresultStatus(const PGresult *res);
extern int PQntuples(const PGresult *res);
extern char *PQgetvalue(const PGresult *res, int tup_num, int field_num);
extern void PQclear(PGresult *res);

#endif
