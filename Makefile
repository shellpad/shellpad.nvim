test:
	docker build . -f tests/Dockerfile --build-arg PLUGIN_NAME=shellpad.nvim -t shellpad/shellpad.nvim:tests
	docker run -it shellpad/shellpad.nvim:tests
