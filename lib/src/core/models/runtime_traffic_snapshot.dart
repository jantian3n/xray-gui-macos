class RuntimeTrafficSnapshot {
  const RuntimeTrafficSnapshot({
    required this.uploadBytesPerSecond,
    required this.downloadBytesPerSecond,
  });

  const RuntimeTrafficSnapshot.zero()
      : uploadBytesPerSecond = 0,
        downloadBytesPerSecond = 0;

  final int uploadBytesPerSecond;
  final int downloadBytesPerSecond;
}
