CXX      = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong
INCLUDES = -Iinclude

SRCS = src/main.cpp \
       src/parser.cpp \
       src/tests.cpp

OBJS = $(SRCS:src/%.cpp=build/%.o)
BIN  = build/pkgtest

.PHONY: all clean

all: $(BIN)

build/%.o: src/%.cpp include/pkgtest.h
	$(shell test -d build || mkdir build)
	$(CXX) $(CXXFLAGS) $(INCLUDES) -c $< -o $@

$(BIN): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ -lstdc++fs

clean:
	rm -rf build