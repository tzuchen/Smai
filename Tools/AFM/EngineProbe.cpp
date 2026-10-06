// Copyright (c) 2026 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

#include "Mandarin/Mandarin.h"
#include "McBopomofoLM.h"
#include "gramambular2/reading_grid.h"

namespace {

using Formosa::Gramambular2::ReadingGrid;
using Formosa::Mandarin::BopomofoKeyboardLayout;
using Formosa::Mandarin::BopomofoReadingBuffer;
using McBopomofo::McBopomofoLM;

std::string JsonEscape(const std::string& input) {
  std::string output;
  output.reserve(input.size() + 8);
  for (unsigned char c : input) {
    switch (c) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\b':
        output += "\\b";
        break;
      case '\f':
        output += "\\f";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          output += buffer;
        } else {
          output += static_cast<char>(c);
        }
        break;
    }
  }
  return output;
}

struct ProbeResult {
  std::vector<std::string> readings;
  std::string baseline;
  std::vector<std::string> candidates;
};

bool BuildReadings(const std::vector<std::string>& tokens,
                   BopomofoReadingBuffer& readingBuffer,
                   std::vector<std::string>& readings) {
  readings.clear();
  for (const std::string& token : tokens) {
    if (token.empty()) {
      return false;
    }
    readingBuffer.clear();
    for (char key : token) {
      if (!readingBuffer.isValidKey(key)) {
        return false;
      }
      if (!readingBuffer.combineKey(key)) {
        return false;
      }
    }
    if (readingBuffer.isEmpty()) {
      return false;
    }
    readings.push_back(readingBuffer.composedString());
  }
  return !readings.empty();
}

bool PopulateGrid(ReadingGrid& grid,
                  const std::vector<std::string>& readings) {
  for (const std::string& reading : readings) {
    if (!grid.insertReading(reading)) {
      return false;
    }
  }
  return true;
}

std::string WalkText(ReadingGrid& grid) {
  const auto walk = grid.walk();
  std::string text;
  for (const std::string& value : walk.valuesAsStrings()) {
    text += value;
  }
  return text;
}

ProbeResult RunProbe(const std::shared_ptr<McBopomofoLM>& languageModel,
                     const std::vector<std::string>& readings) {
  ProbeResult result;
  result.readings = readings;

  ReadingGrid baselineGrid(languageModel);
  if (!PopulateGrid(baselineGrid, readings)) {
    return result;
  }
  result.baseline = WalkText(baselineGrid);

  const size_t lastLoc = readings.size() - 1;
  const auto candidates = baselineGrid.candidatesAt(lastLoc);

  std::unordered_set<std::string> seen;
  seen.insert(result.baseline);
  result.candidates.push_back(result.baseline);

  for (const auto& candidate : candidates) {
    if (result.candidates.size() >= 16) {
      break;
    }
    if (seen.count(candidate.value)) {
      continue;
    }

    ReadingGrid candidateGrid(languageModel);
    if (!PopulateGrid(candidateGrid, readings)) {
      continue;
    }
    if (!candidateGrid.overrideCandidate(lastLoc, candidate)) {
      continue;
    }
    const std::string text = WalkText(candidateGrid);
    if (text.empty() || seen.count(text)) {
      continue;
    }
    seen.insert(text);
    result.candidates.push_back(text);
  }
  return result;
}

std::string BuildJson(const ProbeResult& result) {
  std::string json;
  json.reserve(256);
  json += "{\"backend\":\"McBopomofo\",\"readings\":[";
  for (size_t i = 0; i < result.readings.size(); ++i) {
    if (i > 0) {
      json += ",";
    }
    json += "\"" + JsonEscape(result.readings[i]) + "\"";
  }
  json += "],\"baseline\":\"" + JsonEscape(result.baseline) +
          "\",\"candidates\":[";
  for (size_t i = 0; i < result.candidates.size(); ++i) {
    if (i > 0) {
      json += ",";
    }
    json += "{\"id\":" + std::to_string(i) + ",\"text\":\"" +
            JsonEscape(result.candidates[i]) + "\"}";
  }
  json += "]}";
  return json;
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 3) {
    std::cerr << "Usage: engine-probe <data.txt> <space-separated key tokens>\n";
    return 1;
  }

  const std::string dataPath = argv[1];
  const std::string tokensArg = argv[2];

  std::vector<std::string> tokens;
  {
    std::string current;
    for (char c : tokensArg) {
      if (c == ' ') {
        if (!current.empty()) {
          tokens.push_back(std::move(current));
          current.clear();
        }
      } else {
        current += c;
      }
    }
    if (!current.empty()) {
      tokens.push_back(std::move(current));
    }
  }

  if (tokens.empty()) {
    std::cerr << "No key tokens provided.\n";
    return 1;
  }

  auto languageModel = std::make_shared<McBopomofoLM>();
  languageModel->loadLanguageModel(dataPath.c_str());
  if (!languageModel->isDataModelLoaded()) {
    std::cerr << "Failed to load language model data: " << dataPath << "\n";
    return 1;
  }

  BopomofoReadingBuffer readingBuffer(
      BopomofoKeyboardLayout::StandardLayout());
  std::vector<std::string> readings;
  if (!BuildReadings(tokens, readingBuffer, readings)) {
    std::cerr << "Invalid key sequence or empty reading.\n";
    return 1;
  }

  const ProbeResult result = RunProbe(languageModel, readings);
  if (result.baseline.empty()) {
    std::cerr << "No valid reading produced a baseline.\n";
    return 1;
  }

  std::cout << BuildJson(result) << "\n";
  return 0;
}
