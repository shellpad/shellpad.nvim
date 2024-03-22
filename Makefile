test:
	docker build . -f tests/Dockerfile -t siadat/shell.nvim:tests
	docker run -it siadat/shell.nvim:tests
