import 'package:flutter/material.dart';
import 'package:litert_lm/litert_lm.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LiteRT-LM Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)),
      ),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage> {
  final _modelPathController = TextEditingController();
  final _systemPromptController = TextEditingController(
    text: 'You are a concise on-device assistant.',
  );
  final _promptController = TextEditingController(
    text: 'Say hello from LiteRT-LM.',
  );

  LiteRtLmEngine? _engine;
  LiteRtLmConversation? _conversation;
  String _status = 'Idle';
  String _output = '';
  bool _busy = false;

  @override
  void dispose() {
    _modelPathController.dispose();
    _systemPromptController.dispose();
    _promptController.dispose();
    final conversation = _conversation;
    final engine = _engine;
    if (conversation != null) {
      conversation.dispose();
    }
    if (engine != null) {
      engine.dispose();
    }
    super.dispose();
  }

  Future<void> _prepareEngine() async {
    final modelPath = _modelPathController.text.trim();
    if (modelPath.isEmpty) {
      _setStatus('Enter a model path first.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Preparing engine...';
      _output = '';
    });

    try {
      await _conversation?.dispose();
      await _engine?.dispose();

      final engine = await LiteRtLmEngine.create(
        modelPath: modelPath,
        config: const LmEngineConfig(),
      );
      final conversation = await engine.createConversation(
        conversationConfig: LmConversationConfig(
          systemPrompt: _systemPromptController.text.trim().isEmpty
              ? null
              : _systemPromptController.text.trim(),
        ),
        sessionConfig: const LmSessionConfig(sampler: LmSamplerConfig()),
      );

      if (!mounted) return;
      setState(() {
        _engine = engine;
        _conversation = conversation;
        _status = 'Engine ready';
      });
    } catch (error) {
      if (!mounted) return;
      _setStatus('Prepare failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _sendPrompt() async {
    final conversation = _conversation;
    if (conversation == null) {
      _setStatus('Prepare the engine first.');
      return;
    }

    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      _setStatus('Enter a prompt first.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Generating...';
      _output = '';
    });

    try {
      await for (final chunk in conversation.generateText(prompt)) {
        if (!mounted) return;
        setState(() {
          _output += chunk;
        });
      }
      if (!mounted) return;
      _setStatus('Generation complete');
    } catch (error) {
      if (!mounted) return;
      _setStatus('Generation failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _resetConversation() async {
    final conversation = _conversation;
    if (conversation == null) {
      _setStatus('Prepare the engine first.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Resetting conversation...';
    });

    try {
      await conversation.reset();
      if (!mounted) return;
      setState(() {
        _output = '';
        _status = 'Conversation reset';
      });
    } catch (error) {
      if (!mounted) return;
      _setStatus('Reset failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  void _setStatus(String status) {
    setState(() {
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LiteRT-LM Example')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _modelPathController,
              decoration: const InputDecoration(
                labelText: 'Model Path',
                hintText: '/absolute/path/to/model.litertlm',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _systemPromptController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'System Prompt',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _prepareEngine,
              child: const Text('Prepare Engine'),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _promptController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _sendPrompt,
                    child: const Text('Generate'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _resetConversation,
                    child: const Text('Reset'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(_status),
                    const SizedBox(height: 16),
                    Text(
                      'Output',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _output.isEmpty ? 'No output yet.' : _output,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
