import 'package:flutter/foundation.dart';

/// Cursor-based pagination envelope. The server owns paging.
/// The client only asks for the next cursor.
@immutable
class PagedResult<T> {
  const PagedResult({
    required this.items,
    this.nextCursor,
    this.hasMore = false,
  });

  final List<T> items;
  final String? nextCursor;
  final bool hasMore;
}
