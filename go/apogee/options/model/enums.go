package model

type OptionType string

const (
	OptionTypeCall OptionType = "call"
	OptionTypePut  OptionType = "put"
)

type OptionStyle string

const (
	OptionStyleAmerican OptionStyle = "american"
	OptionStyleEuropean OptionStyle = "european"
)

type OptionExercise string

const (
	OptionExerciseLong  OptionExercise = "long"
	OptionExerciseShort OptionExercise = "short"
)

type OptionMoneyness string

const (
	OptionMoneynessInTheMoney    OptionMoneyness = "ITM"
	OptionMoneynessOutOfTheMoney OptionMoneyness = "OTM"
	OptionMoneynessAtTheMoney    OptionMoneyness = "ATM"
)
