cmake_minimum_required(VERSION 3.16)
project(qgate_fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(qgate_fixture STATIC src/greeting.cpp)
target_include_directories(qgate_fixture PUBLIC src)