// ignore_for_file: invalid_use_of_internal_member
// The lint above is okay, because we're using another Sentry package

import 'package:dio/dio.dart';
import 'package:http/http.dart';
import 'package:mockito/mockito.dart';
import 'package:sentry/sentry.dart';
import 'package:sentry/src/sentry_tracer.dart';
import 'package:sentry_dio/src/tracing_client_adapter.dart';
import 'package:test/test.dart';

import 'mocks.dart';
import 'mocks/mock_http_client_adapter.dart';
import 'mocks/mock_transport.dart';

final requestUri = Uri.parse('https://example.com?foo=bar');
final requestOptions = '?foo=bar';

void main() {
  group(TracingClientAdapter, () {
    late Fixture fixture;

    setUp(() {
      fixture = Fixture();
    });

    test('captured span if successful request', () async {
      final sut = fixture.getSut(
        client: fixture.getClient(statusCode: 200, reason: 'OK'),
      );
      final tr = fixture._hub.startTransaction(
        'name',
        'op',
        bindToScope: true,
      );

      await sut.get<dynamic>(requestOptions);

      await tr.finish();

      final tracer = (tr as SentryTracer);
      final span = tracer.children.first;

      expect(span.status, SpanStatus.ok());
      expect(span.context.operation, 'http.client');
      expect(span.context.description, 'GET https://example.com?foo=bar');
    });

    test('finish span if errored request', () async {
      final sut = fixture.getSut(
        client: createThrowingClient(),
      );
      final tr = fixture._hub.startTransaction(
        'name',
        'op',
        bindToScope: true,
      );

      try {
        await sut.get<dynamic>(requestOptions);
      } catch (_) {
        // ignore
      }

      await tr.finish();

      final tracer = (tr as SentryTracer);
      final span = tracer.children.first;

      expect(span.finished, isTrue);
    });

    test('associate exception to span if errored request', () async {
      final sut = fixture.getSut(
        client: createThrowingClient(),
      );
      final tr = fixture._hub.startTransaction(
        'name',
        'op',
        bindToScope: true,
      );

      dynamic exception;
      try {
        await sut.get<dynamic>(requestOptions);
      } catch (error) {
        exception = error;
      }

      await tr.finish();

      final tracer = (tr as SentryTracer);
      final span = tracer.children.first;

      expect(span.status, SpanStatus.internalError());
      expect(span.throwable, isA<TestException>());
      expect(exception, isA<DioError>());
      expect((exception as DioError).error, isA<TestException>());
    });

    test('captured span adds sentry-trace header to the request', () async {
      final sut = fixture.getSut(
        client: fixture.getClient(statusCode: 200, reason: 'OK'),
      );
      final tr = fixture._hub.startTransaction(
        'name',
        'op',
        bindToScope: true,
      );

      final response = await sut.get<dynamic>(requestOptions);

      await tr.finish();

      final tracer = (tr as SentryTracer);
      final span = tracer.children.first;

      expect(
        response.headers['sentry-trace'],
        <String>[span.toSentryTrace().value],
      );
    });

    test('captured span do not add headers if NoOp', () async {
      final sut = fixture.getSut(
        client: fixture.getClient(statusCode: 200, reason: 'OK'),
      );
      await fixture._hub
          .configureScope((scope) => scope.span = NoOpSentrySpan());

      final response = await sut.get<dynamic>(requestOptions);

      expect(response.headers['baggage'], null);
      expect(response.headers['sentry-trace'], null);
    });

    test('do not throw if no span bound to the scope', () async {
      final sut = fixture.getSut(
        client: fixture.getClient(statusCode: 200, reason: 'OK'),
      );

      await sut.get<dynamic>(requestOptions);
    });
  });
}

MockHttpClientAdapter createThrowingClient() {
  return MockHttpClientAdapter(
    (options, _, __) async {
      expect(options.uri, requestUri);
      throw TestException();
    },
  );
}

class CloseableMockClient extends Mock implements BaseClient {}

class Fixture {
  final _options = SentryOptions(dsn: fakeDsn);
  late Hub _hub;
  final transport = MockTransport();
  Fixture() {
    _options.transport = transport;
    _options.tracesSampleRate = 1.0;
    _hub = Hub(_options);
  }

  Dio getSut({MockHttpClientAdapter? client}) {
    final mc = client ?? getClient();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
    dio.httpClientAdapter = TracingClientAdapter(
      client: mc,
      hub: _hub,
    );
    return dio;
  }

  MockHttpClientAdapter getClient({int statusCode = 200, String? reason}) {
    return MockHttpClientAdapter((options, requestStream, cancelFuture) async {
      expect(options.uri, requestUri);
      return ResponseBody.fromString(
        '',
        statusCode,
        headers: options.headers.map(
          (key, dynamic value) =>
              MapEntry(key, <String>[value?.toString() ?? '']),
        ),
      );
    });
  }
}

class TestException implements Exception {}
