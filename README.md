# nim-e2e-reliability
Nim implementation of the e2e reliability protocol

# Building

## Android

Download the latest Android NDK. For example, on Ubuntu Intel:

```code
cd ~
wget https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
```
```code
unzip android-ndk-r27c-linux.zip
```

Then, add the following to your ~/.bashrc file:
```code
export ANDROID_NDK_HOME=$HOME/android-ndk-r27c
export PATH=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
```

Then, use one of the following commands, according to the current architecture:

| Architecture | command |
| arm64 | make libsds-android ARCH=arm64 |
| amd64 | make libsds-android ARCH=amd64 |
| x86 | make libsds-android ARCH=x86 |

At the end of the process, the library will be created in build/libsds.so

## Windows, Linux or MacOS

```code
make libsds
```


