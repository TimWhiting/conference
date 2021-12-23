import 'dart:io';
import 'dart:isolate';

import 'package:puppeteer/puppeteer.dart';
import 'package:dartx/dartx.dart';
import 'package:http/http.dart' as http;

void main() async {
  // Download the Chromium binaries, launch it and connect to the "DevTools"
  var browser = await puppeteer.launch(headless: true);

  final langs = ['eng'];
  // Iterate through the conferences and launch async tabs handling each then await the completion
  await Future.wait([
    for (final year in 2010.rangeTo(2019))
      for (final month in ['10', '04'])
        handleConference(browser, langs, month, year)
  ]);

  // Gracefully close the browser's process
  await Future.delayed(Duration(seconds: 1));
  await browser.close();
}

Future<void> handleConference(
  Browser browser,
  List<String> langs,
  String month,
  int year,
) async {
  // Open a new tab
  var myPage = await browser.newPage();

  final talks = <String>[];

  // Go to the overall conference page
  await myPage.goto(
    'https://www.churchofjesuschrist.org/study/general-conference/$year/$month',
    wait: Until.networkIdle,
  );
  // get all of the talks
  for (final talk in await myPage.$$('a.listTile-WHLxI')) {
    final href = await myPage.evaluate('element => element.href', args: [talk]);
    talks.add(href);
  }

  // Prepare the directories for each language
  for (final lang in langs) {
    Directory('$lang/$year/$month').createSync(recursive: true);
  }
  // Go to each of the talks pages
  for (final talk in talks.where((t) => !t.toLowerCase().contains('session'))) {
    await myPage.goto(talk, wait: Until.networkIdle);
    // Find the buttons across the top
    final buttons = await myPage.$$('div.baseHeaderMenuItem-sPKOf > button');
    // Download is second button
    final button = buttons[1];
    // hit the download button
    await button.tap();
    // find the download link
    final download = await myPage.$$('div.yoesbz-2 a');
    // get the href
    final link = Uri.parse(
      await myPage.evaluate('element => element.href', args: [download.first]),
    );
    // Spawn a thread to download the talk
    Isolate.spawn(downloadAndSave, [link, talk, langs]);
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

    final year = url.pathSegments.last.substring(0, 4);
    final month = url.pathSegments.last.substring(5, 7);
    final title = url.pathSegments.last.substring(13);

    /// Unfortunately not all conferences were in April and October (e.g. 2015)
    Directory('$lang/$year/$month').createSync(recursive: true);

    if (!title.contains('sustaining-of-general') &&
        !title.contains('sustaining-of-church') &&
        !title.contains('auditing-department')) {
      final dir = Directory('$lang/$year/$month');
      final file = File('${dir.path}/$talkIndex$title');
      // Don't redownload if the file already exists
      if (!file.existsSync()) {
        final download = await http.get(url);
        print('Downloading ${dir.path}/$talkIndex$title from $url');
        file.writeAsBytesSync(download.bodyBytes);
      }
    }
  }
}
