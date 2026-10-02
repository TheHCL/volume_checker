import AVFoundation
import SoundAnalysis

/// 一次辨識結果：Apple 內建分類器的標籤與信心度（0~1）。
struct SoundGuess: Equatable {
    let identifier: String
    let confidence: Double

    var name: String { SoundLabels.name(for: identifier) }
    var isSilence: Bool { identifier == "silence" }
}

/// 用 Apple 內建的聲音分類模型（SoundAnalysis，約 300 種聲音）在本機辨識聲音類型。
/// 不需要網路，也不會錄音或上傳。
final class SoundClassifier: NSObject, SNResultsObserving {
    private let queue = DispatchQueue(label: "VolumeChecker.analysis")
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0
    private var failed = false

    private let onResult: ([SoundGuess]) -> Void
    private let onError: (String) -> Void

    init(onResult: @escaping ([SoundGuess]) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    /// 可從任何執行緒呼叫；buffer 必須是已複製出來、不會再被修改的資料。
    func analyze(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            if failed { return }
            if analyzer == nil || format != buffer.format {
                setUp(for: buffer.format)
            }
            analyzer?.analyze(buffer, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(buffer.frameLength)
        }
    }

    func stop() {
        queue.async { [self] in
            analyzer?.completeAnalysis()
            analyzer = nil
            format = nil
            framePosition = 0
        }
    }

    private func setUp(for format: AVAudioFormat) {
        analyzer?.removeAllRequests()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // 預設約 1 秒一個片段；重疊一半，大約每 0.5 秒更新一次。
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: self)
        } catch {
            failed = true
            onError("無法啟動聲音辨識：\(error.localizedDescription)")
            return
        }
        self.analyzer = analyzer
        self.format = format
        framePosition = 0
    }

    // MARK: - SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let top = result.classifications
            .sorted { $0.confidence > $1.confidence }
            .prefix(3)
            .map {
            SoundGuess(identifier: $0.identifier, confidence: $0.confidence)
        }
        onResult(top)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError("聲音辨識發生錯誤：\(error.localizedDescription)")
    }
}

/// 把分類器的英文標籤翻成中文；沒有列在表中的就顯示原本的英文。
enum SoundLabels {
    static func name(for identifier: String) -> String {
        if let name = names[identifier] { return name }
        return identifier.replacingOccurrences(of: "_", with: " ")
    }

    private static let names: [String: String] = [
        // 交通
        "car_horn": "汽車喇叭",
        "air_horn": "氣笛喇叭",
        "truck_horn": "卡車喇叭",
        "siren": "警笛",
        "police_siren": "警車警笛",
        "ambulance_siren": "救護車警笛",
        "fire_engine_siren": "消防車警笛",
        "civil_defense_siren": "防空警報",
        "emergency_vehicle": "緊急車輛",
        "vehicle": "車輛",
        "car": "汽車",
        "car_passing_by": "車輛經過",
        "race_car": "賽車",
        "motorcycle": "機車",
        "motor_vehicle_road": "道路車輛",
        "traffic_noise": "車流聲",
        "traffic_noise_roadway_noise": "車流聲",
        "truck": "卡車",
        "bus": "公車",
        "train": "火車",
        "train_horn": "火車鳴笛",
        "train_whistle": "火車汽笛",
        "train_wheels_squealing": "火車輪聲",
        "rail_transport": "軌道列車",
        "railroad_car": "火車車廂",
        "subway_metro": "捷運",
        "airplane": "飛機",
        "aircraft": "飛機",
        "jet_engine": "噴射引擎",
        "propeller_airscrew": "螺旋槳",
        "helicopter": "直升機",
        "engine": "引擎聲",
        "engine_idling": "引擎怠速",
        "engine_starting": "引擎發動",
        "engine_accelerating_revving": "引擎加速",
        "engine_knocking": "引擎爆震",
        "heavy_engine": "重型引擎",
        "light_engine": "小型引擎",
        "tire_squeal": "輪胎摩擦聲",
        "skidding": "煞車打滑",
        "reversing_beeps": "倒車警示音",
        "bicycle": "腳踏車",
        "bicycle_bell": "腳踏車鈴",
        "skateboard": "滑板",
        "boat_water_vehicle": "船",
        // 人聲
        "speech": "說話聲",
        "conversation": "交談聲",
        "chatter": "交談聲",
        "shout": "喊叫聲",
        "yell": "吼叫聲",
        "screaming": "尖叫聲",
        "whispering": "悄悄話",
        "laughter": "笑聲",
        "giggling": "笑聲",
        "crying_sobbing": "哭聲",
        "baby_crying": "嬰兒哭聲",
        "children_shouting": "小孩叫聲",
        "crowd": "人群",
        "cheering": "歡呼聲",
        "applause": "鼓掌聲",
        "singing": "歌聲",
        "choir_singing": "合唱",
        "cough": "咳嗽",
        "sneeze": "打噴嚏",
        "snoring": "打呼",
        "footsteps": "腳步聲",
        // 動物
        "dog": "狗",
        "dog_bark": "狗叫聲",
        "dog_bow_wow": "狗叫聲",
        "dog_howl": "狗嚎叫",
        "dog_growl": "狗低吼",
        "cat": "貓",
        "cat_meow": "貓叫聲",
        "bird": "鳥",
        "bird_chirp_tweet": "鳥叫聲",
        "bird_vocalization": "鳥叫聲",
        "crow_caw": "烏鴉叫",
        "pigeon_dove_coo": "鴿子叫",
        "rooster_crow": "雞啼",
        "chicken": "雞",
        "insect": "昆蟲",
        "cricket_chirp": "蟋蟀聲",
        "mosquito_buzz": "蚊子聲",
        "frog": "青蛙",
        // 音樂
        "music": "音樂",
        "drum": "鼓聲",
        "drum_kit": "爵士鼓",
        "bass_drum": "大鼓",
        "guitar": "吉他",
        "electric_guitar": "電吉他",
        "piano": "鋼琴",
        "loudspeaker": "擴音器",
        // 施工、機械
        "jackhammer": "電鑽／破碎機",
        "drill": "電鑽",
        "power_tool": "電動工具",
        "hammer": "敲打聲",
        "sawing": "鋸東西",
        "chainsaw": "鏈鋸",
        "lawn_mower": "割草機",
        "construction": "施工聲",
        "mechanical_fan": "風扇",
        "air_conditioner": "冷氣",
        "vacuum_cleaner": "吸塵器",
        "hair_dryer": "吹風機",
        "blender": "果汁機",
        "washing_machine": "洗衣機",
        // 環境
        "wind": "風聲",
        "wind_noise_microphone": "麥克風風噪",
        "rain": "雨聲",
        "raindrop": "雨滴",
        "thunder": "雷聲",
        "thunderstorm": "雷雨",
        "water": "水聲",
        "water_tap_faucet": "水龍頭",
        "stream_burbling": "溪流聲",
        "ocean": "海浪聲",
        "fire": "火燒聲",
        // 居家、其他
        "door": "門",
        "door_slam": "甩門聲",
        "door_bell": "門鈴",
        "knock": "敲門聲",
        "bell": "鈴聲",
        "church_bell": "教堂鐘聲",
        "bicycle_bell_ring": "腳踏車鈴",
        "alarm_clock": "鬧鐘",
        "smoke_detector": "煙霧警報器",
        "telephone": "電話",
        "telephone_bell_ringing": "電話鈴聲",
        "ringtone": "手機鈴聲",
        "television": "電視",
        "radio": "收音機",
        "dishes_pots_and_pans": "碗盤聲",
        "chopping_food": "切菜聲",
        "glass_breaking": "玻璃破碎",
        "fireworks": "煙火",
        "firecracker": "鞭炮",
        "gunshot_gunfire": "爆裂聲",
        "explosion": "爆炸聲",
        "boom": "轟隆聲",
        "silence": "安靜",
    ]
}
