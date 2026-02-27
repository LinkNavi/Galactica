CXX      = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong
INCLUDES = -Iinclude

SRCS = src/main.cpp \
       src/parser.cpp \
       src/mapper.cpp \
       src/fetcher.cpp \
       src/writer.cpp \
       src/index.cpp \
       src/git.cpp

OBJS = $(SRCS:src/%.cpp=build/%.o)
BIN  = build/ebuild2pkg

.PHONY: all clean

all: $(BIN)

build/%.o: src/%.cpp include/ebuild.h
	mkdir -p build
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(BIN): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ -lstdc++fs

clean:
	rm -rf build
