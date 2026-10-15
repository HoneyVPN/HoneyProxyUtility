// Test-only adapter for running the pure C# fixtures in bundled PowerShell on
// macOS/Linux. Shipping Windows compilation uses the real .NET Framework
// JavaScriptSerializer; this source is never a service build input.
using System;
using System.Collections.Generic;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace System.Web.Script.Serialization {
    public sealed class JavaScriptSerializer {
        public int MaxJsonLength { get; set; }
        public int RecursionLimit { get; set; }
        public string Serialize(object value) {
            var options = new JsonSerializerOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, MaxDepth = RecursionLimit };
            var result = JsonSerializer.Serialize(value, options);
            if (result.Length > MaxJsonLength) throw new InvalidOperationException("startFailed");
            return result;
        }
        public object DeserializeObject(string value) {
            if (value.Length > MaxJsonLength) throw new InvalidOperationException("startFailed");
            using (var document = JsonDocument.Parse(value, new JsonDocumentOptions { MaxDepth = RecursionLimit })) {
                return Convert(document.RootElement);
            }
        }
        private static object Convert(JsonElement value) {
            switch (value.ValueKind) {
                case JsonValueKind.Object:
                    var map = new Dictionary<string, object>(StringComparer.Ordinal);
                    foreach (var property in value.EnumerateObject()) map[property.Name] = Convert(property.Value);
                    return map;
                case JsonValueKind.Array:
                    var items = new List<object>();
                    foreach (var item in value.EnumerateArray()) items.Add(Convert(item));
                    return items.ToArray();
                case JsonValueKind.String: return value.GetString();
                case JsonValueKind.True: return true;
                case JsonValueKind.False: return false;
                case JsonValueKind.Null: return null;
                case JsonValueKind.Number:
                    int small; if (value.TryGetInt32(out small)) return small;
                    long large; if (value.TryGetInt64(out large)) return large;
                    return value.GetDecimal();
                default: throw new InvalidOperationException("startFailed");
            }
        }
    }
}
