// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Generated file. Do not edit.

package fletch;

public class Uint8ListBuilder {
  private ListBuilder builder;

  public Uint8ListBuilder(ListBuilder builder) { this.builder = builder; }

  public int get(int index) {
    return builder.segment.getUnsigned(builder.base + index * 1);
  }

  public int set(int index, int value) {
    builder.segment.buffer().put(builder.base + index * 1, (byte)value);    return value;
  }

  public int size() { return builder.length; }
}
