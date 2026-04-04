import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────
const String _kSavedFolders = 'saved_folders';

// Offset besar agar PageView terasa infinite
const int _kInfiniteOffset = 100000;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const MyApp());
}

// ─────────────────────────────────────────────
// ROOT APP
// ─────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reel Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const VideoFeedScreen(),
    );
  }
}

// ─────────────────────────────────────────────
// MAIN FEED SCREEN
// ─────────────────────────────────────────────
class VideoFeedScreen extends StatefulWidget {
  const VideoFeedScreen({super.key});

  @override
  State<VideoFeedScreen> createState() => _VideoFeedScreenState();
}

class _VideoFeedScreenState extends State<VideoFeedScreen> {
  List<File> _videoFiles = [];
  bool _hasPermission = false;
  bool _isLoading = false;

  // Real index dalam _videoFiles
  int _realIndex = 0;

  // PageController dengan offset besar untuk infinite feel
  late PageController _pageController;

  // Cache controller: key = real index dalam _videoFiles
  final Map<int, VideoPlayerController> _controllers = {};

  // Folder yang aktif saat ini
  List<String> _activeFolders = [];

  // Default folder fallback
  static const List<String> _defaultDirs = [
    '/storage/emulated/0/DCIM/Camera',
    '/storage/emulated/0/Movies',
    '/storage/emulated/0/DCIM',
    '/storage/emulated/0/Download',
  ];

  // ── LIFECYCLE ────────────────────────────────
  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _kInfiniteOffset);
    _checkPermission();
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  // ── PERMISSION ──────────────────────────────
  Future<void> _checkPermission() async {
    PermissionStatus status = await Permission.videos.status;
    if (!status.isGranted) {
      status = await Permission.storage.status;
    }
    if (status.isGranted) {
      setState(() => _hasPermission = true);
      await _loadSavedFolders();
    } else {
      setState(() => _hasPermission = false);
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _isLoading = true);
    PermissionStatus status = await Permission.videos.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }
    if (status.isGranted) {
      setState(() => _hasPermission = true);
      await _loadSavedFolders();
    } else if (status.isPermanentlyDenied) {
      openAppSettings();
    }
    if (mounted) setState(() => _isLoading = false);
  }

  // ── PERSISTENCE ──────────────────────────────
  Future<void> _loadSavedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kSavedFolders);
    if (saved != null && saved.isNotEmpty) {
      _activeFolders = saved;
    } else {
      _activeFolders = List.from(_defaultDirs);
    }
    await _loadVideos();
  }

  Future<void> _saveFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSavedFolders, folders);
  }

  // ── FOLDER PICKER ────────────────────────────
  Future<void> _openFolderPicker() async {
    _controllers[_realIndex]?.pause();

    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pilih Folder Video',
    );

    if (result != null && result.isNotEmpty) {
      if (!_activeFolders.contains(result)) {
        _activeFolders.add(result);
        await _saveFolders(_activeFolders);
        if (mounted) {
          _showToast('Folder ditambahkan: ${result.split('/').last}');
        }
        await _reloadVideos();
      } else {
        if (mounted) _showToast('Folder sudah ada dalam daftar');
        _controllers[_realIndex]?.play();
      }
    } else {
      _controllers[_realIndex]?.play();
    }
  }

  Future<void> _removeFolder(String folder) async {
    _activeFolders.remove(folder);
    await _saveFolders(_activeFolders);
    await _reloadVideos();
  }

  Future<void> _reloadVideos() async {
    for (final ctrl in _controllers.values) {
      await ctrl.dispose();
    }
    _controllers.clear();
    _realIndex = 0;

    if (_pageController.hasClients) {
      _pageController.jumpToPage(_kInfiniteOffset);
    }
    await _loadVideos();
  }

  // ── LOAD VIDEO FILES ─────────────────────────
  Future<void> _loadVideos() async {
    setState(() => _isLoading = true);

    final List<File> found = [];
    const extensions = ['.mp4', '.mkv', '.mov', '.avi', '.3gp', '.webm'];

    for (final dirPath in _activeFolders) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;
      try {
        final entities = dir.listSync(recursive: false);
        for (final entity in entities) {
          if (entity is File) {
            final lower = entity.path.toLowerCase();
            if (extensions.any((ext) => lower.endsWith(ext))) {
              if (!found.any((f) => f.path == entity.path)) {
                found.add(entity);
              }
            }
          }
        }
      } catch (_) {}
    }

    found.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );

    setState(() {
      _videoFiles = found;
      _isLoading = false;
    });

    if (found.isNotEmpty) {
      await _preloadControllers(0);
    }
  }

  // ── CONTROLLER MANAGEMENT ────────────────────
  Future<void> _preloadControllers(int realIndex) async {
    if (_videoFiles.isEmpty) return;
    final count = _videoFiles.length;

    final needed = <int>{
      (realIndex - 1 + count) % count,
      realIndex,
      (realIndex + 1) % count,
    };

    // Dispose yang tidak dibutuhkan
    final toRemove = _controllers.keys
        .where((k) => !needed.contains(k))
        .toList();
    for (final k in toRemove) {
      await _controllers[k]?.dispose();
      _controllers.remove(k);
    }

    // Init controller baru
    for (final i in needed) {
      if (!_controllers.containsKey(i)) {
        final ctrl = VideoPlayerController.file(_videoFiles[i]);
        _controllers[i] = ctrl;
        try {
          await ctrl.initialize();
          await ctrl.setLooping(true);
          await ctrl.setVolume(1.0);
        } catch (_) {
          await ctrl.dispose();
          _controllers.remove(i);
        }
      }
    }

    // Play current, pause lainnya
    for (final entry in _controllers.entries) {
      if (entry.key == realIndex) {
        entry.value.play();
      } else {
        entry.value.pause();
      }
    }

    if (mounted) setState(() {});
  }

  int _pageToReal(int page) {
    if (_videoFiles.isEmpty) return 0;
    return page % _videoFiles.length;
  }

  void _onPageChanged(int page) {
    final real = _pageToReal(page);
    setState(() => _realIndex = real);
    _preloadControllers(real);
  }

  // ── ABOUT DIALOG ─────────────────────────────
  void _openAbout() {
    _controllers[_realIndex]?.pause();
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (_) => const _AboutDialog(),
    ).then((_) => _controllers[_realIndex]?.play());
  }

  // ── SETTINGS SHEET ───────────────────────────
  void _openSettings() {
    _controllers[_realIndex]?.pause();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SettingsSheet(
        activeFolders: List.from(_activeFolders),
        onAddFolder: _openFolderPicker,
        onRemoveFolder: _removeFolder,
        onRefresh: _reloadVideos,
      ),
    ).then((_) => _controllers[_realIndex]?.play());
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: Colors.white.withOpacity(0.12),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── BUILD ────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.black, body: _buildBody());
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoadingScreen();
    if (!_hasPermission) return _buildPermissionScreen();
    if (_videoFiles.isEmpty) return _buildEmptyScreen();
    return _buildFeed();
  }

  // ── PERMISSION SCREEN ────────────────────────
  Widget _buildPermissionScreen() {
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _GlassCard(
                  padding: const EdgeInsets.all(28),
                  radius: 28,
                  child: const Icon(
                    Icons.video_library_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Akses Video',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Izinkan akses ke penyimpanan\nuntuk memutar video dari galeri kamu.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.white.withOpacity(0.55),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 40),
                _MacButton(
                  label: 'Izinkan Akses',
                  icon: Icons.lock_open_rounded,
                  onTap: _requestPermission,
                  isPrimary: true,
                ),
                const SizedBox(height: 12),
                _MacButton(
                  label: 'Buka Pengaturan',
                  icon: Icons.settings_rounded,
                  onTap: openAppSettings,
                  isPrimary: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── LOADING SCREEN ───────────────────────────
  Widget _buildLoadingScreen() {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
            const SizedBox(height: 20),
            Text(
              'Memuat video...',
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── EMPTY SCREEN ─────────────────────────────
  Widget _buildEmptyScreen() {
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.videocam_off_rounded,
                  size: 64,
                  color: Colors.white.withOpacity(0.25),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Tidak ada video',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Folder yang dipilih tidak memiliki video.\nCoba pilih folder lain.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.45),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),
                _MacButton(
                  label: 'Pilih Folder',
                  icon: Icons.folder_open_rounded,
                  onTap: _openFolderPicker,
                  isPrimary: true,
                ),
                const SizedBox(height: 12),
                _MacButton(
                  label: 'Coba Lagi',
                  icon: Icons.refresh_rounded,
                  onTap: _reloadVideos,
                  isPrimary: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── VIDEO FEED ───────────────────────────────
  Widget _buildFeed() {
    final total = _videoFiles.length;
    return Stack(
      children: [
        // PageView infinite (itemCount: null)
        PageView.builder(
          controller: _pageController,
          scrollDirection: Axis.vertical,
          itemCount: null, // null = truly infinite
          onPageChanged: _onPageChanged,
          itemBuilder: (context, page) {
            final real = _pageToReal(page);
            return VideoPageItem(
              key: ValueKey('vid_$real'),
              file: _videoFiles[real],
              controller: _controllers[real],
              realIndex: real,
              total: total,
            );
          },
        ),

        // Top bar: counter + settings
        Positioned(
          top: MediaQuery.of(context).padding.top + 12,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _GlassChip(label: '${_realIndex + 1} / $total'),
              Row(
                children: [
                  _GlassIconButton(
                    icon: Icons.info_outline_rounded,
                    onTap: _openAbout,
                  ),
                  const SizedBox(width: 8),
                  _GlassIconButton(
                    icon: Icons.tune_rounded,
                    onTap: _openSettings,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// SETTINGS BOTTOM SHEET
// ─────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  final List<String> activeFolders;
  final VoidCallback onAddFolder;
  final Future<void> Function(String) onRemoveFolder;
  final Future<void> Function() onRefresh;

  const _SettingsSheet({
    required this.activeFolders,
    required this.onAddFolder,
    required this.onRemoveFolder,
    required this.onRefresh,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late List<String> _folders;

  @override
  void initState() {
    super.initState();
    _folders = List.from(widget.activeFolders);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.07),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              // Handle bar
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Folder Video',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        widget.onAddFolder();
                      },
                      child: _GlassCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        radius: 10,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.add_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Tambah',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
              Divider(color: Colors.white.withOpacity(0.1), height: 1),

              // Folder list
              Flexible(
                child: _folders.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Belum ada folder.\nKetuk Tambah untuk memilih folder.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: _folders.length,
                        separatorBuilder: (_, __) => Divider(
                          color: Colors.white.withOpacity(0.07),
                          height: 1,
                        ),
                        itemBuilder: (_, i) {
                          final folder = _folders[i];
                          final name = folder.split('/').last;
                          return ListTile(
                            leading: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.folder_rounded,
                                color: Colors.white54,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              folder,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.35),
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: GestureDetector(
                              onTap: () async {
                                setState(() => _folders.remove(folder));
                                await widget.onRemoveFolder(folder);
                              },
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close_rounded,
                                  color: Colors.redAccent,
                                  size: 16,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: _MacButton(
                  label: 'Muat Ulang Video',
                  icon: Icons.refresh_rounded,
                  onTap: () {
                    Navigator.pop(context);
                    widget.onRefresh();
                  },
                  isPrimary: false,
                ),
              ),

              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SINGLE VIDEO PAGE
// ─────────────────────────────────────────────
class VideoPageItem extends StatefulWidget {
  final File file;
  final VideoPlayerController? controller;
  final int realIndex;
  final int total;

  const VideoPageItem({
    super.key,
    required this.file,
    required this.controller,
    required this.realIndex,
    required this.total,
  });

  @override
  State<VideoPageItem> createState() => _VideoPageItemState();
}

class _VideoPageItemState extends State<VideoPageItem>
    with SingleTickerProviderStateMixin {
  bool _showControls = false;

  // Animasi ikon play/pause di tengah layar
  bool _showCenterIcon = false;
  bool _lastWasPlaying = false; // ikon yang ditampilkan: play atau pause
  late final AnimationController _iconAnimCtrl;
  late final Animation<double> _iconScaleAnim;
  late final Animation<double> _iconOpacityAnim;

  @override
  void initState() {
    super.initState();
    _iconAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _iconScaleAnim = TweenSequence([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.6,
          end: 1.15,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.15,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.8,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
    ]).animate(_iconAnimCtrl);
    _iconOpacityAnim = TweenSequence([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 40),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 35,
      ),
    ]).animate(_iconAnimCtrl);
  }

  @override
  void dispose() {
    _iconAnimCtrl.dispose();
    super.dispose();
  }

  // Tap → toggle play/pause + tampilkan ikon sebentar
  void _onTap() {
    final ctrl = widget.controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      _toggleControls();
      return;
    }

    final wasPlaying = ctrl.value.isPlaying;
    wasPlaying ? ctrl.pause() : ctrl.play();

    // Rekam ikon yang akan ditampilkan SETELAH aksi
    setState(() {
      _lastWasPlaying = wasPlaying; // jika sedang play → sekarang pause, dst.
      _showCenterIcon = true;
    });

    _iconAnimCtrl.forward(from: 0).then((_) {
      if (mounted) setState(() => _showCenterIcon = false);
    });

    // Juga toggle info bar
    _toggleControls();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showControls = false);
      });
    }
  }

  void _togglePlay() {
    final ctrl = widget.controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final wasPlaying = ctrl.value.isPlaying;
    wasPlaying ? ctrl.pause() : ctrl.play();
    setState(() {
      _lastWasPlaying = wasPlaying;
      _showCenterIcon = true;
    });
    _iconAnimCtrl.forward(from: 0).then((_) {
      if (mounted) setState(() => _showCenterIcon = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return GestureDetector(
      onTap: _onTap,
      onDoubleTap: _togglePlay,
      child: Container(
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── VIDEO ─────────────────────────
            if (ctrl != null && ctrl.value.isInitialized)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: ctrl.value.size.width,
                    height: ctrl.value.size.height,
                    child: VideoPlayer(ctrl),
                  ),
                ),
              )
            else
              Container(
                color: const Color(0xFF090909),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation(
                          Colors.white.withOpacity(0.3),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _basename(widget.file.path),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.25),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── PROGRESS BAR ──────────────────
            if (ctrl != null && ctrl.value.isInitialized)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: VideoProgressIndicator(
                  ctrl,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.white12,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),

            // ── CENTER PLAY/PAUSE ICON ────────
            if (_showCenterIcon)
              IgnorePointer(
                child: AnimatedBuilder(
                  animation: _iconAnimCtrl,
                  builder: (_, __) => Opacity(
                    opacity: _iconOpacityAnim.value.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: _iconScaleAnim.value,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(50),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.18),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withOpacity(0.35),
                                width: 1.5,
                              ),
                            ),
                            child: Icon(
                              // _lastWasPlaying = video WAS playing → sekarang pause
                              _lastWasPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 42,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // ── OVERLAY CONTROLS ──────────────
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    // Gradient vignette
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.45),
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black.withOpacity(0.65),
                          ],
                        ),
                      ),
                    ),

                    // Glass info bar bawah
                    Positioned(
                      bottom: 24,
                      left: 16,
                      right: 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.09),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.15),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _basename(widget.file.path),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (ctrl != null &&
                                          ctrl.value.isInitialized) ...[
                                        const SizedBox(height: 3),
                                        Text(
                                          _formatDuration(ctrl.value.duration),
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.5,
                                            ),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Play/Pause button
                                GestureDetector(
                                  onTap: _togglePlay,
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.18),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withOpacity(0.28),
                                      ),
                                    ),
                                    child: Icon(
                                      (ctrl != null && ctrl.value.isPlaying)
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 26,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── SWIPE HINT ────────────────────
            if (widget.realIndex == 0 && widget.total > 1 && !_showControls)
              const Positioned(bottom: 90, child: _SwipeHint()),
          ],
        ),
      ),
    );
  }

  String _basename(String path) => path.split('/').last;

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ─────────────────────────────────────────────
// ABOUT DIALOG — macOS Sonoma Glass Style
// ─────────────────────────────────────────────
class _AboutDialog extends StatelessWidget {
  const _AboutDialog();

  Future<void> _launchInstagram() async {
    final uri = Uri.parse('https://instagram.com/agunggandr');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
          child: Container(
            decoration: BoxDecoration(
              // Gradien halus seperti vibrancy macOS Sonoma
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.14),
                  Colors.white.withOpacity(0.06),
                ],
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withOpacity(0.22),
                width: 1.2,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(28, 36, 28, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Avatar / App Icon ──────────
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.35),
                        Colors.white.withOpacity(0.1),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 1.5,
                    ),
                  ),
                  child: const Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 38,
                  ),
                ),

                const SizedBox(height: 20),

                // ── App name ──────────────────
                const Text(
                  'Reel Player',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.4,
                  ),
                ),

                const SizedBox(height: 6),

                // ── Nama (besar & bold) ───────
                const Text(
                  'Agung Andrianto',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    height: 1.1,
                  ),
                ),

                const SizedBox(height: 18),

                // ── Divider glass ─────────────
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.white.withOpacity(0.25),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // ── Instagram (tappable) ──────
                GestureDetector(
                  onTap: _launchInstagram,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          // Warna khas Instagram (gradient ungu-oranye)
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFE1306C).withOpacity(0.25),
                              const Color(0xFF833AB4).withOpacity(0.25),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFE1306C).withOpacity(0.35),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Instagram icon (manual paint — tidak perlu package)
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFFF58529),
                                    Color(0xFFE1306C),
                                    Color(0xFF833AB4),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(
                                Icons.photo_camera_rounded,
                                color: Colors.white,
                                size: 13,
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              '@agunggandr',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.1,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.open_in_new_rounded,
                              color: Colors.white.withOpacity(0.5),
                              size: 14,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // ── Close button ──────────────
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.2),
                          ),
                        ),
                        child: const Text(
                          'Tutup',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // ── Footer ────────────────────
                Text(
                  'Handcrafted with ❤️ on Linux Mint',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.35),
                    fontSize: 11,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// KOMPONEN UI — macOS Glassmorphism
// ─────────────────────────────────────────────

/// Glass card generik dengan blur
class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  const _GlassCard({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withOpacity(0.18)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Ikon bulat glass (settings button)
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _GlassIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(50),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.13),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Tombol macOS — primary solid putih / secondary glass
class _MacButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isPrimary;

  const _MacButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    if (isPrimary) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withOpacity(0.12),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: Colors.black),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Secondary = glass
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chip counter dengan blur
class _GlassChip extends StatelessWidget {
  final String label;
  const _GlassChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.13),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// Swipe hint animasi bounce
class _SwipeHint extends StatefulWidget {
  const _SwipeHint();

  @override
  State<_SwipeHint> createState() => _SwipeHintState();
}

class _SwipeHintState extends State<_SwipeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0,
      end: -10,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, _anim.value),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.09),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.14)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.keyboard_arrow_up_rounded,
                    color: Colors.white60,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Geser ke atas',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.65),
                      fontSize: 12,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
