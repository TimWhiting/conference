import 'dart:io';
import 'dart:isolate';

import 'package:dartx/dartx.dart';
import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:puppeteer/puppeteer.dart';

void main() async {
  // Download the Chromium binaries, launch it and connect to the "DevTools"
  var browser = await puppeteer.launch(headless: true);

  final langs = ['eng'];
  // Iterate through the conferences and launch async tabs handling each then await the completion
  // await Future.wait([
  //   // for (final year in 2019.rangeTo(2024))
  //   //   for (final month in ['10', '04'])
  //   //     handleConferenceTalks(browser, langs, month, year),
  //   for (final year in 2019.rangeTo(2024))
  //     for (final month in ['october', 'april'])
  //       handleConference(browser, langs, month, year)
  // ]);
  await downloadSpeeches(browser);

  // Gracefully close the browser's process
  await Future.delayed(Duration(seconds: 1));
  await browser.close();
}

Future<void> downloadSpeeches(
  Browser browser,
) async {
  var myPage = await browser.newPage();
  await myPage.goto('https://speeches.byu.edu/speakers/',
      wait: Until.domContentLoaded);
  final speakers = await myPage.$$('h3 > a');
  final speakerUrls = await Future.wait([
    for (final speaker in speakers)
      myPage.evaluate('element => element.href', args: [speaker])
  ]);
  print('Found ${speakerUrls.length} speakers');
  for (final speakerUrl in speakerUrls) {
    print('Visiting $speakerUrl');
    await myPage.goto(speakerUrl, wait: Until.all([]));
    await Future.delayed(Duration(milliseconds: 50));
    print("finding speeches for $speakerUrl");
    final speeches = await myPage.$$('.media-links__icon--download');
    print('Found ${speeches.length} speeches for $speakerUrl');
    for (final (i, speechDownloadButton) in speeches.indexed) {
      await speechDownloadButton.click();
      final speaker = await myPage.$$('.single-speaker__name');
      final speakerName = await myPage
          .evaluate('element => element.textContent', args: [speaker[0]]);
      print('Processing speech $i for $speakerName');
      final mp3Link = await myPage.$$('a[href*=".mp3"]');
      final url = await Future.wait(mp3Link
          .map((e) => myPage.evaluate('element => element.href', args: [e])));
      final title = await myPage.$$('article h2 a');
      final titleText = await myPage
          .evaluate('element => element.textContent', args: [title[i]]);
      if (mp3Link.isNotEmpty) {
        final file = File('speeches/$speakerName/${titleText.trim()}.mp3');
        if (!file.existsSync()) {
          file.parent.createSync(recursive: true);
          final download = await http.get(Uri.parse(url.first as String));
          print('Downloading ${file.path} from $url');
          await file.writeAsBytes(download.bodyBytes, flush: true);
        } else {
          print('Skipping ${file.path}: already downloaded');
        }
      }
    }
  }
}

Future<void> handleConference(
  Browser browser,
  List<String> langs,
  String month,
  int year,
) async {
  // Open a new tab
  var myPage = await browser.newPage();

  final songs = <String, String>{};

  // Go to the overall conference page
  await myPage.goto(
    'https://www.churchofjesuschrist.org/media/music/collections/music-from-$month-$year-general-conference?lang=eng',
    wait: Until.networkAlmostIdle, // Until.networkIdle,
  ); // https://www.churchofjesuschrist.org/media/music/songs/2024-10-press-forward-saints?...lang=eng
  // get all of the talks
  final allSongs = await myPage.$$('details a');
  for (final talk in allSongs) {
    final href = await myPage.evaluate('element => element.href', args: [talk]);
    songs[href] = '';
  }
  for (final song in songs.keys) {
    try {
      await myPage.goto(song, wait: Until.networkAlmostIdle);
      final audio = await myPage.$$("audio");
      final src =
          await myPage.evaluate('element => element.src', args: [audio[0]]);
      // print('song: $src');
      songs[song] = src;
    } catch (e) {
      print(e);
    }
  }
  print(
      "Songs: ${songs.mapEntries((e) => "${e.key.split('/').last}: ${e.value}").join("\n")}");
  await Isolate.spawn(downloadSongs, [songs, langs[0], month, year]);
  await Future.delayed(Duration(seconds: 20));
  await myPage.close();
}

Future<void> downloadSongs(List args) async {
  final songs = args[0] as Map<String, String>;
  final lang = args[1] as String;
  final month = args[2] as String;
  final year = args[3] as int;
  final dir = Directory('$lang/$year/$month');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final client = http.Client();
  Future.wait([
    for (final entry in songs.entries)
      if (entry.value != "") downloadSong(client, dir, entry.key, entry.value)
  ]);
}

Future<void> downloadSong(
    Client client, Directory dir, String song, String urlString) async {
  try {
    print("Going to download $song");
    final url = Uri.parse(urlString);
    final title = urlString.split('/').last;
    final file = File('${dir.path}/$title');
    // Don't redownload if the file already exists
    if (!file.existsSync()) {
      final download = await client.get(url);
      print('Downloading ${dir.path}/$title from $url');
      await file.writeAsBytes(download.bodyBytes, flush: true);
    } else {
      print('Skipping $title: already downloaded');
    }
  } catch (e) {
    print("ERRORRRRRRR!!!!!");
    print(e);
    await Future.delayed(Duration(seconds: 1));
  }
}

Future<void> handleConferenceTalks(
  Browser browser,
  List<String> langs,
  String month,
  int year,
) async {
  // Open a new tab
  var myPage = await browser.newPage();

  // Go to the overall conference page
  await myPage.goto(
    'https://www.churchofjesuschrist.org/study/general-conference/$year/$month',
  );
  // get all of the talks
  var allTalks =
      await myPage.$$('li[data-content-type="general-conference-talk"] > a');
  if (allTalks.isEmpty) {
    allTalks = await myPage.$$('.listTile-WHLxI');
  }
  final talks = (await Future.wait([
    for (final talk in allTalks)
      myPage.evaluate('element => element.href', args: [talk])
  ]))
      .cast<String>();
  print(talks);

  // Prepare the directories for each language
  for (final lang in langs) {
    Directory('$lang/$year/$month').createSync(recursive: true);
  }
  // Go to each of the talks pages
  for (final talk in talks.where((t) => !t.toLowerCase().contains('session'))) {
    await myPage.goto(talk, wait: Until.networkAlmostIdle);
    print("Processing talk: $talk");
    // Find the buttons across the top
    final audioPlayer = await myPage.$$('button[aria-label="Audio Player"]');
    // Tap the audio player button
    await audioPlayer[0].tap();
    final title = await myPage.$$('h1');
    final titleText = await myPage
        .evaluate('element => element.textContent', args: [title[0]]);

    final more = await myPage.$$('button[aria-label="More"]');
    // find the download link
    await more[0].tap();

    final download = await myPage.$$('a[href*="download=true"]');
    final List<dynamic> hrefs =
        (await Future.wait(download.map((eh) => eh.evaluate('e => e.href'))));
    print(hrefs);
    // get the href
    final link =
        Uri.parse(hrefs.firstWhere((href) => href.contains('download')));
    // Spawn a thread to download the talk
    Isolate.spawn(downloadAndSave, [link, talk, langs, titleText]);
  }
  await myPage.close();
}

void downloadAndSave(List params) async {
  // Save fore each language
  for (final lang in params[2] as List<String>) {
    // Sample download url
    // https://media2.ldscdn.org/assets/general-conference/april-2021-general-conference/2021-04-4010-ulisses-soares-32k-eng.mp3?lang=eng&download=true
    var url = params[0] as Uri;
    url = url.replace(path: url.path.replaceAll('-eng', '-$lang'));
    // Sample talk url
    // www.churchofjesuschrist.org/study/general-conference/2021/04/57nelson

    final talk = Uri.parse(params[1] as String);
    // Need index because some speakers speak more than once
    var talkIndex = talk.pathSegments.last.substring(0, 2);
    // Some urls use talk name instead of speaker name. Talk name is unique
    // /study/general-conference/2017/10/turn-on-your-light
    talkIndex = talkIndex.isInt ? talkIndex : '';

    final year = talk.pathSegments.drop(2).first;
    final month = talk.pathSegments.drop(3).first;
    final title = params[3];

    /// Unfortunately not all conferences were in April and October (e.g. 2015)
    Directory('$lang/$year/$month').createSync(recursive: true);

    if (!title.contains('Church Auditing') &&
        !title.contains('Sustaining of General Authorities, Area Seventies')) {
      final dir = Directory('$lang/$year/$month');
      final file = File('${dir.path}/$title.mp3');
      // Don't redownload if the file already exists
      if (!file.existsSync()) {
        final download = await http.get(url);
        print('Downloading ${dir.path}/$title from $url');
        file.writeAsBytesSync(download.bodyBytes);
      }
    }
  }
}
