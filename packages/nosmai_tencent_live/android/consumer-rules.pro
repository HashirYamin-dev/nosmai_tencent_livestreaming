# Tencent RTC is driven through Dart FFI and JNI; Nosmai calls back from native.
-keep class com.tencent.** { *; }
-dontwarn com.tencent.**
-keep class com.nosmai.** { *; }
-dontwarn com.nosmai.**
-keepclasseswithmembernames class * { native <methods>; }
