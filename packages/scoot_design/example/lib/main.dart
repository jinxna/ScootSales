import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import 'dashboard_scenes.dart';
import 'frames.dart';
import 'phone_scenes.dart';

final List<GalleryScene> allScenes = <GalleryScene>[
  ...dashboardScenes,
  ...phoneScenes,
];

void main() => runApp(const GalleryApp());

class GalleryApp extends StatefulWidget {
  const GalleryApp({super.key});

  @override
  State<GalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<GalleryApp> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final GalleryScene scene = allScenes[_index];
    return MaterialApp(
      title: 'Scoot design gallery',
      debugShowCheckedModeBanner: false,
      theme: ScootTheme.dashboard(),
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 320,
              child: ListView.builder(
                itemCount: allScenes.length,
                itemBuilder: (BuildContext context, int i) => ListTile(
                  selected: i == _index,
                  title: Text(allScenes[i].title),
                  subtitle: Text(allScenes[i].id),
                  onTap: () => setState(() => _index = i),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FittedBox(
                  alignment: Alignment.topCenter,
                  child: SceneFrame(
                    key: ValueKey<String>(scene.id),
                    scene: scene,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
