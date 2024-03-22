FROM ubuntu:20.04

ENV NVIM_VERSION v0.9.5

RUN apt-get update
# wget is required for downloading nvim
# git is required by Lazy
RUN apt-get install -y wget git

WORKDIR /work
RUN wget https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-linux64.tar.gz
RUN tar xvzf nvim-linux64.tar.gz
ENV PATH="/work/nvim-linux64/bin:${PATH}"

COPY test.bash /work/test.bash
ENTRYPOINT ["/work/test.bash"]
