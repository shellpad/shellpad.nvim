test:
	docker build . -f tests/Dockerfile --build-arg PLUGIN_NAME=shell.nvim -t siadat/shell.nvim:tests
	docker run -it siadat/shell.nvim:tests
