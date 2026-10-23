import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const bg = Color(0xFF12141A);
const card = Color(0xFF1C2029);
const amber = Color(0xFFF2B134);
const muted = Color(0xFFA3A9B8);

final notifs = FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  await notifs.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ));
  await notifs
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
  runApp(const VaultApp());
}

/// ---------------------------------------------------------------
/// VAULT: copy, lock check, notification. All the logic lives here.
/// ---------------------------------------------------------------
class Vault {
  // Android "time since boot" clock: ignores the phone's date/time settings.
  static const _clock = MethodChannel('vault/clock');

  static Future<int?> _mono() async {
    try {
      return await _clock.invokeMethod<int>('elapsed');
    } catch (_) {
      return null; // iOS or error: fall back to wall clock
    }
  }

  // The copy lives in the app's private folder (invisible to the gallery).
  static Future<File> file() async {
    final p = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/vault.${p.getString('ext') ?? 'jpg'}');
  }

  static Future<void> lock(XFile src, Duration d) async {
    final p = await SharedPreferences.getInstance();
    final ext = src.name.contains('.') ? src.name.split('.').last : 'jpg';
    await p.setString('ext', ext);
    await (await file()).writeAsBytes(await src.readAsBytes()); // real copy
    final now = DateTime.now().millisecondsSinceEpoch;
    await p.setInt('dur', d.inMilliseconds);
    await p.setInt('lockMono', await _mono() ?? -1);
    await p.setInt('unlockAt', now + d.inMilliseconds);
    await p.setInt('hwm', now); // "latest time ever seen"
    await p.setBool('has', true);
    if (p.getBool('notify') ?? true) await _schedule(d);
  }

  /// Time left, or null if nothing is locked. <= 0 means ready.
  static Future<Duration?> remaining() async {
    final p = await SharedPreferences.getInstance();
    if (!(p.getBool('has') ?? false)) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stored = p.getInt('hwm') ?? now;
    final hwm = max(stored, now); // clock can never go backwards for us
    if (now - stored >= 60000) await p.setInt('hwm', hwm);

    final mono = await _mono();
    final lockMono = p.getInt('lockMono') ?? -1;
    final int ms;
    if (mono != null && lockMono >= 0 && mono >= lockMono) {
      // No reboot: count real elapsed time, clock changes do nothing.
      ms = p.getInt('dur')! - (mono - lockMono);
    } else {
      // After a reboot (or on iOS): use the clock, guarded by hwm.
      ms = p.getInt('unlockAt')! - hwm;
    }
    return Duration(milliseconds: ms);
  }

  static Future<void> _schedule(Duration d) async {
    await notifs.zonedSchedule(
      1,
      'Your image is ready',
      'Tap to reveal it.',
      tz.TZDateTime.now(tz.UTC).add(d),
      const NotificationDetails(
        android: AndroidNotificationDetails('vault', 'Vault',
            importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  static Future<void> setNotify(bool on, Duration rem) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('notify', on);
    if (on && rem > Duration.zero) {
      await _schedule(rem);
    } else {
      await notifs.cancel(1);
    }
  }

  static Future<void> clear() async {
    final f = await file();
    if (await f.exists()) await f.delete();
    final p = await SharedPreferences.getInstance();
    for (final k in ['has', 'dur', 'lockMono', 'unlockAt', 'hwm', 'ext']) {
      await p.remove(k);
    }
    await notifs.cancel(1);
  }
}

/// ---------------------------------------------------------------
/// UI: Empty -> Locked -> Ready -> Choice
/// ---------------------------------------------------------------
class VaultApp extends StatelessWidget {
  const VaultApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: bg,
          colorScheme: const ColorScheme.dark(primary: amber),
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  Duration? rem;
  bool revealed = false;
  bool notify = true;
  XFile? picked;
  Duration? choice;
  String? choiceLabel;
  File? img;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final r = await Vault.remaining();
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      rem = r;
      notify = p.getBool('notify') ?? true;
    });
  }

  // ---- actions ----
  Future<void> pick() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x != null) setState(() => picked = x);
  }

  Future<void> pickTime() async {
    final t = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 18, minute: 0));
    if (t == null) return;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    setState(() {
      choice = at.difference(now);
      choiceLabel = 'At ${t.format(context)}';
    });
  }

  Future<void> lockIt() async {
    await Vault.lock(picked!, choice!);
    setState(() {
      picked = null;
      choice = null;
      choiceLabel = null;
    });
    refresh();
  }

  Future<void> reveal() async {
    final f = await Vault.file();
    setState(() {
      img = f;
      revealed = true;
    });
  }

  Future<void> finish() async {
    await Vault.clear();
    setState(() {
      revealed = false;
      img = null;
    });
    refresh();
  }

  Future<void> save() async {
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Gal.putImage(img!.path);
      await finish(); // wipe the vault only after a successful save
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not save. Try again.')));
    }
  }

  Future<void> askDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete forever?'),
        content: const Text('The image will be gone for good.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await finish();
  }

  // ---- helpers ----
  String fmt(Duration d) {
    String t(int n) => n.toString().padLeft(2, '0');
    return '${t(d.inHours)}:${t(d.inMinutes % 60)}:${t(d.inSeconds % 60)}';
  }

  Widget btn(String label, VoidCallback? onTap,
      {Color fill = amber, Color text = bg, Color? border}) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: fill,
          foregroundColor: text,
          disabledBackgroundColor: const Color(0xFF2A2F3B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: border == null ? BorderSide.none : BorderSide(color: border, width: 1.5),
          ),
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      ),
    );
  }

  Widget tag() => const Align(
        alignment: Alignment.centerLeft,
        child: Text('VAULT', style: TextStyle(fontSize: 13, letterSpacing: 1.5, color: muted)),
      );

  // ---- screens ----
  Widget emptyScreen() => Column(children: [
        tag(),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            InkResponse(
              onTap: pick,
              child: Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: amber, width: 2),
                ),
                child: Icon(picked == null ? Icons.add : Icons.check, size: 56, color: amber),
              ),
            ),
            const SizedBox(height: 20),
            Text(picked == null ? 'Nothing locked yet' : 'Image selected',
                style: const TextStyle(fontSize: 18, color: muted)),
          ]),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Unlock', style: TextStyle(fontSize: 15, color: muted)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: btn('In 6h', picked == null ? null : () => setState(() {
                      choice = const Duration(hours: 6);
                      choiceLabel = 'In 6h';
                    }),
                    fill: choiceLabel == 'In 6h' ? amber : const Color(0xFF2A2F3B),
                    text: choiceLabel == 'In 6h' ? bg : Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: btn(
                    choiceLabel != null && choiceLabel != 'In 6h' ? choiceLabel! : 'At time…',
                    picked == null ? null : pickTime,
                    fill: choiceLabel != null && choiceLabel != 'In 6h'
                        ? amber
                        : const Color(0xFF2A2F3B),
                    text: choiceLabel != null && choiceLabel != 'In 6h' ? bg : Colors.white),
              ),
            ]),
            const SizedBox(height: 14),
            btn('Lock it', picked != null && choice != null ? lockIt : null,
                fill: Colors.white, text: bg),
          ]),
        ),
      ]);

  Widget lockedScreen() {
    final at = DateTime.now().add(rem!);
    return Column(children: [
      tag(),
      Expanded(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.lock_outline, size: 72, color: amber),
          const SizedBox(height: 18),
          Text(fmt(rem!),
              style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w300, letterSpacing: 2)),
          const SizedBox(height: 18),
          Text('Opens at ${TimeOfDay.fromDateTime(at).format(context)}',
              style: const TextStyle(fontSize: 18, color: muted)),
        ]),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(16)),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Notify me when it opens'),
          value: notify,
          onChanged: (v) async {
            await Vault.setNotify(v, rem!);
            refresh();
          },
        ),
      ),
    ]);
  }

  Widget readyScreen() => Column(children: [
        tag(),
        const Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.lock_open_outlined, size: 72, color: amber),
            SizedBox(height: 18),
            Text('Your image is ready',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
          ]),
        ),
        btn('Reveal', reveal),
      ]);

  Widget choiceScreen() => Column(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: img == null
                ? const SizedBox()
                : Image.file(img!, fit: BoxFit.contain, width: double.infinity),
          ),
        ),
        const SizedBox(height: 20),
        btn('Save to gallery', save),
        const SizedBox(height: 10),
        btn('Delete forever', askDelete,
            fill: Colors.transparent, text: const Color(0xFFFF8A80), border: const Color(0xFFFF8A80)),
      ]);

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (revealed) {
      body = choiceScreen();
    } else if (rem == null) {
      body = emptyScreen();
    } else if (rem! > Duration.zero) {
      body = lockedScreen();
    } else {
      body = readyScreen();
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.fromLTRB(28, 24, 28, 24), child: body),
      ),
    );
  }
}
