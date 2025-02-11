# adapted from https://github.com/waku-org/nwaku/blob/master/waku/common/protobuf.nim

{.push raises: [].}

import libp2p/protobuf/minprotobuf
import libp2p/varint

export minprotobuf, varint

type
  ProtobufErrorKind* {.pure.} = enum
    DecodeFailure
    MissingRequiredField

  ProtobufError* = object
    case kind*: ProtobufErrorKind
    of DecodeFailure:
      error*: minprotobuf.ProtoError
    of MissingRequiredField:
      field*: string

  ProtobufResult*[T] = Result[T, ProtobufError]

converter toProtobufError*(err: minprotobuf.ProtoError): ProtobufError =
  case err
  of minprotobuf.ProtoError.RequiredFieldMissing:
    ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: "unknown")
  else:
    ProtobufError(kind: ProtobufErrorKind.DecodeFailure, error: err)

proc missingRequiredField*(T: type ProtobufError, field: string): T =
  ProtobufError(kind: ProtobufErrorKind.MissingRequiredField, field: field)
