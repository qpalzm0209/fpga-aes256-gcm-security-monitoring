CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror -std=c11
LDLIBS += -lcrypto

.PHONY: all clean test

all: test_ecdh_session_crypto aes-session-agent

test_ecdh_session_crypto: test_ecdh_session_crypto.o ecdh_session_crypto.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

aes-session-agent: aes_session_agent.o aes_session_regs.o ecdh_session_crypto.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

test: test_ecdh_session_crypto
	./test_ecdh_session_crypto
	sh ./test_session_recovery.sh
	bash ./test_init_supervision.sh
	bash ./test_wifi_recovery.sh

clean:
	rm -f test_ecdh_session_crypto aes-session-agent *.o
