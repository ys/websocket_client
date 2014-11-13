SHELL := /bin/bash
PROJECT = websocket_client

include erlang.mk

test-deps:
	git clone https://github.com/extend/cowboy.git test-deps/cowboy
	pushd test-deps/cowboy; git checkout 0.9.0; make; popd
	git clone https://github.com/ferd/recon.git test-deps/recon
	pushd test-deps/recon; ./rebar compile; popd

test: test-deps all
	mkdir -p .ct_results
	ct_run -pa test-deps/*/ebin test-deps/cowboy/deps/*/ebin ebin \
	-dir ct \
	-logdir ./.ct_results \
	-cover ct/websocket_client.coverspec
