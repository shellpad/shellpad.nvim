test:
	docker build ./tests -t siadat/shell.nvim:tests
	docker run -it siadat/shell.nvim:tests
