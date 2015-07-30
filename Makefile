SHELL := /bin/bash
PROJECT = websocket_client

TEST_DEPS = cowboy recon proper
CT_SUITES = wc wsc_lib

include erlang.mk
