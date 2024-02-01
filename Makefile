CC = gcc
CFLAGS = -fPIC -g -Wall -Wextra -O2 -Werror
LDFLAGS = -shared -lcbor -lcjson -lsqlite3
RM = rm -f
TARGET_LIB = cbor_to_json.so

SRCS = src/cbor_to_json.c
OBJS = $(SRCS:.c=.o)

.PHONY: all
all: ${TARGET_LIB}

$(TARGET_LIB): $(OBJS)
	$(CC) ${LDFLAGS} -o $@ $^

$(SRCS:.c=.d):%.d:%.c
	$(CC) $(CFLAGS) -MM $< >$@

include $(SRCS:.c=.d)

.PHONY: clean
clean:
	-${RM} ${TARGET_LIB} ${OBJS} $(SRCS:.c=.d)
